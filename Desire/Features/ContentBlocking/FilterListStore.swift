import Combine
import Foundation
import os
import WebKit

/// Manages community filter lists (EasyList China / EasyList): downloads the
/// ABP-format list, converts it on-device (ABPRuleConverter), compiles it
/// into a cached WKContentRuleList, and recompiles every
/// `updateInterval` days. Compiled lists are selectively added/removed from
/// registered controllers — NEVER via removeAllContentRuleLists, which would
/// wipe ContentBlockerStore's lists on the same controllers.
@MainActor
class FilterListStore: ObservableObject {
    static let shared = FilterListStore()
    static let updateInterval: TimeInterval = 7 * 24 * 3600

    struct ListState: Identifiable {
        let id: String
        let name: String
        let subtitle: String
        let sourceURL: URL
        var isEnabled: Bool
        var lastUpdated: Date?
        var ruleCount: Int?
        var isUpdating: Bool = false
        var errorText: String? = nil
    }

    struct ListMeta: Codable {
        var enabled: Bool = false
        var lastUpdated: Date?
        var ruleCount: Int?
    }

    @Published private(set) var lists: [ListState] = []

    private let definitions: [ListState] = [
        // China list is ON by default: it is the single highest-value
        // first-run feature, and the fetch/compile runs in the background.
        ListState(id: "easylist-china", name: "EasyList China", subtitle: "中文广告过滤（国内网站）",
                  sourceURL: URL(string: "https://easylist-downloads.adblockplus.org/easylistchina.txt")!, isEnabled: true),
        ListState(id: "easylist", name: "EasyList", subtitle: "国际广告过滤（英文网站）",
                  sourceURL: URL(string: "https://easylist-downloads.adblockplus.org/easylist.txt")!, isEnabled: false),
    ]

    private var compiled: [String: WKContentRuleList] = [:]
    private var metas: [String: ListMeta] = [:]

    private struct WeakController { weak var controller: WKUserContentController? }
    private var registered: [WeakController] = []
    /// What this store added to each controller, for selective removal.
    private var addedRuleLists: [ObjectIdentifier: [(id: String, list: WKContentRuleList)]] = [:]

    /// One in-flight update task PER list — a single handle would let
    /// refreshing one list cancel the other's download mid-flight.
    private var updateTasks: [String: Task<Void, Never>] = [:]
    private let metaKey = "filterLists.meta"
    private nonisolated static let fetchSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// 规则列表 store。
    ///
    /// `WKContentRuleListStore.default()` 在个别环境下会返回 nil——表现是**所有**
    /// 列表都得到"Compilation failed"，而日志里没有任何编译错误（两个 compile 分支
    /// 都不会被走到）。兜底用基于目录的 store：编译只依赖它的缓存目录，编译出来的
    /// `WKContentRuleList` 是内存对象，注册到 controller 与 store 是谁无关。
    private static func ruleListStore() -> WKContentRuleListStore? {
        if let store = WKContentRuleListStore.default() { return store }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Desire", isDirectory: true)
            .appendingPathComponent("ContentRuleLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Log.contentBlocking.error("default content-rule store unavailable — falling back to a directory store at \(dir.path, privacy: .public)")
        return WKContentRuleListStore(url: dir)
    }

    private init() {
        metas = DiskStore.load([String: ListMeta].self, key: metaKey) ?? [:]
        lists = definitions.map { def in
            var state = def
            if let meta = metas[def.id] {
                state.isEnabled = meta.enabled
                state.lastUpdated = meta.lastUpdated
                state.ruleCount = meta.ruleCount
            }
            return state
        }
        loadCachedCompilations()
    }

    /// Loads rule lists WebKit persisted from previous runs; enabled lists
    /// with no cached compilation are fetched in the background.
    private func loadCachedCompilations() {
        guard let store = Self.ruleListStore() else {
            Log.contentBlocking.error("no content-rule store available — filter lists cannot load")
            return
        }
        for list in lists where list.isEnabled {
            let id = list.id
            Task { [weak self] in
                let cached = try? await store.contentRuleList(forIdentifier: Self.ruleListIdentifier(id))
                guard let cached else {
                    self?.refresh(id: id)
                    return
                }
                self?.install(id: id, compiled: cached, lastUpdated: self?.metas[id]?.lastUpdated, ruleCount: self?.metas[id]?.ruleCount)
                self?.updateIfNeeded()
            }
        }
        updateIfNeeded()
    }

    // MARK: - Public API

    func apply(to config: WKWebViewConfiguration) {
        let controller = config.userContentController
        registered.removeAll { $0.controller == nil }
        guard !registered.contains(where: { $0.controller === controller }) else { return }
        registered.append(WeakController(controller: controller))
        for list in lists where list.isEnabled {
            if let compiledList = compiled[Self.ruleListIdentifier(list.id)] {
                controller.add(compiledList)
                addedRuleLists[ObjectIdentifier(controller), default: []].append((list.id, compiledList))
            }
        }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[i].isEnabled = enabled
        metas[id, default: ListMeta()].enabled = enabled
        saveMeta()
        if enabled {
            if let compiledList = compiled[Self.ruleListIdentifier(id)] {
                addEverywhere(id: id, list: compiledList)
            } else {
                refresh(id: id) // first enable — fetch and compile
            }
        } else {
            removeEverywhere(id: id)
        }
    }

    /// Fetches + converts + compiles a list. Skips when the cached
    /// compilation is younger than `updateInterval` unless `force`.
    func refresh(id: String, force: Bool = false) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        guard lists[i].isEnabled else { return }
        if lists[i].isUpdating { return }
        if !force,
           let last = lists[i].lastUpdated,
           Date().timeIntervalSince(last) < Self.updateInterval,
           compiled[Self.ruleListIdentifier(id)] != nil {
            return
        }
        let sourceURL = lists[i].sourceURL
        lists[i].isUpdating = true
        lists[i].errorText = nil
        updateTasks[id]?.cancel()
        updateTasks[id] = Task { [weak self] in
            await self?.updateList(id: id, sourceURL: sourceURL)
        }
    }

    func updateIfNeeded() {
        for list in lists where list.isEnabled {
            let stale = list.lastUpdated == nil
                || Date().timeIntervalSince(list.lastUpdated!) >= Self.updateInterval
            if stale { refresh(id: list.id) }
        }
    }

    // MARK: - Update pipeline

    private func updateList(id: String, sourceURL: URL) async {
        do {
            var request = URLRequest(url: sourceURL)
            request.timeoutInterval = 30
            let (data, _) = try await Self.fetchSession.data(for: request)
            let abp = String(data: data, encoding: .utf8) ?? ""
            guard !abp.isEmpty else {
                throw NSError(domain: "FilterList", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Empty filter list"])
            }
            // 代理/门户可能把请求劫持成 HTML 错误页——非空但注定编译失败，
            // 提前拦下并报真实原因。
            let head = abp.prefix(2048).lowercased()
            if head.contains("<!doctype html") || head.contains("<html") {
                throw NSError(domain: "FilterList", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Source returned an HTML page, not a rule list"])
            }

            guard let compiledList = await compile(id: id, abp: abp) else {
                throw NSError(domain: "FilterList", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Compilation failed"])
            }
            try? abp.write(to: rawFileURL(id), atomically: true, encoding: .utf8)

            let count = ABPRuleConverter.convert(abp).ruleCount
            markMeta(id: id, lastUpdated: Date(), ruleCount: count)
            install(id: id, compiled: compiledList, lastUpdated: Date(), ruleCount: count)
            if let i = lists.firstIndex(where: { $0.id == id }) {
                lists[i].isUpdating = false
                lists[i].errorText = nil
            }
            if lists.first(where: { $0.id == id })?.isEnabled == true {
                addEverywhere(id: id, list: compiledList)
            }
            Log.contentBlocking.info("filter list \(id, privacy: .public) updated — \(count) rules")
        } catch {
            if let i = lists.firstIndex(where: { $0.id == id }) {
                lists[i].isUpdating = false
                lists[i].errorText = error.localizedDescription
            }
            Log.contentBlocking.error("filter list \(id, privacy: .public) update failed: \(error.localizedDescription)")
        }
    }

    /// Compiles with element hiding; on failure retries blocking-only so one
    /// bad selector can't take the whole list down.
    /// WKContentRuleListStore's removal has no async import on this SDK —
    /// wrap the completion handler.
    private func removeStoredList(_ identifier: String) async {
        guard let store = Self.ruleListStore() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }

    /// 一次转换 + 编译（带完整错误日志）。
    private func attempt(store: WKContentRuleListStore, identifier: String, abp: String, includeHiding: Bool) async -> WKContentRuleList? {
        let converted = ABPRuleConverter.convert(abp, includeHiding: includeHiding)
        guard converted.ruleCount > 0 else { return nil }
        do {
            return try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: converted.json)
        } catch {
            let ns = error as NSError
            Log.contentBlocking.error("filter list compile failed (\(includeHiding ? "full" : "blocking-only", privacy: .public)): \(ns.domain, privacy: .public)/\(ns.code, privacy: .public) — \(ns.userInfo, privacy: .public) — json \(converted.json.count, privacy: .public)B")
            return nil
        }
    }

    /// 编译失败时的**自愈**：二分找出 WebKit 不接受的规则丢掉，用剩下的重新编译。
    ///
    /// 列表里只要有一条正则/写法 WebKit 不认，整份列表就编译失败（实测 EasyList
    /// 全量因此一直"更新失败"）。逐层二分把坏行定位到很小的块再丢；代价只发生在
    /// 失败路径上（成功路径仍然只编译一次）。
    private func sanitize(store: WKContentRuleListStore, identifier: String, text: String, depth: Int = 0) async -> (kept: String, dropped: [String]) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1, depth < 14 else {
            let meaningful = lines.filter { !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[Adblock") }
            return ("", meaningful)
        }
        let mid = lines.count / 2
        var kept: [String] = []
        var dropped: [String] = []
        for chunk in [Array(lines[..<mid]), Array(lines[mid...])] {
            let chunkText = chunk.joined(separator: "\n")
            let converted = ABPRuleConverter.convert(chunkText, includeHiding: true)
            if converted.ruleCount == 0 { continue }   // 整块都是注释/不支持的行
            let probeID = identifier + "-probe"
            await removeStoredList(probeID)
            let ok: Bool
            do {
                _ = try await store.compileContentRuleList(forIdentifier: probeID, encodedContentRuleList: converted.json)
                ok = true
            } catch {
                ok = false
            }
            if ok {
                kept.append(contentsOf: chunk)
            } else {
                let (good, bad) = await sanitize(store: store, identifier: identifier, text: chunkText, depth: depth + 1)
                if !good.isEmpty {
                    kept.append(contentsOf: good.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                }
                dropped.append(contentsOf: bad)
            }
        }
        return (kept.joined(separator: "\n"), dropped)
    }

    private func compile(id: String, abp: String) async -> WKContentRuleList? {
        guard let store = Self.ruleListStore() else {
            Log.contentBlocking.error("filter list \(id, privacy: .public) compile skipped: no content-rule store")
            return nil
        }
        let identifier = Self.ruleListIdentifier(id)
        await removeStoredList(identifier)
        if let list = await attempt(store: store, identifier: identifier, abp: abp, includeHiding: true) {
            return list
        }
        await removeStoredList(identifier)
        if let list = await attempt(store: store, identifier: identifier, abp: abp, includeHiding: false) {
            return list
        }
        // 两条路都失败：二分剔除 WebKit 不接受的规则，把剩下的编译出来（自愈）。
        await removeStoredList(identifier)
        let (kept, dropped) = await sanitize(store: store, identifier: identifier, text: abp)
        guard !dropped.isEmpty else { return nil }
        Log.contentBlocking.error("filter list \(id, privacy: .public) dropped \(dropped.count, privacy: .public) unsupported rule(s); first: \(dropped.prefix(3).joined(separator: " | "), privacy: .public)")
        await removeStoredList(identifier)
        guard let list = await attempt(store: store, identifier: identifier, abp: kept, includeHiding: true) else {
            Log.contentBlocking.error("filter list \(id, privacy: .public) still fails after dropping \(dropped.count, privacy: .public) rule(s)")
            return nil
        }
        return list
    }

    // MARK: - Controller distribution

    private func install(id: String, compiled: WKContentRuleList, lastUpdated: Date?, ruleCount: Int?) {
        let had = self.compiled.updateValue(compiled, forKey: Self.ruleListIdentifier(id))
        if let i = lists.firstIndex(where: { $0.id == id }) {
            lists[i].lastUpdated = lastUpdated ?? lists[i].lastUpdated
            lists[i].ruleCount = ruleCount ?? lists[i].ruleCount
        }
        _ = had
    }

    private func addEverywhere(id: String, list: WKContentRuleList) {
        removeEverywhere(id: id) // never add twice to the same controller
        for box in registered {
            guard let controller = box.controller else { continue }
            controller.add(list)
            addedRuleLists[ObjectIdentifier(controller), default: []].append((id, list))
        }
    }

    private func removeEverywhere(id: String) {
        for box in registered {
            guard let controller = box.controller else { continue }
            let key = ObjectIdentifier(controller)
            guard var added = addedRuleLists[key] else { continue }
            let matched = added.filter { $0.id == id }
            added.removeAll { $0.id == id }
            addedRuleLists[key] = added
            for entry in matched { controller.remove(entry.list) }
        }
    }

    // MARK: - Helpers

    nonisolated static func ruleListIdentifier(_ id: String) -> String {
        "filterlist-" + id
    }

    private func rawFileURL(_ id: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Desire", isDirectory: true).appendingPathComponent("filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).txt")
    }

    private func markMeta(id: String, lastUpdated: Date, ruleCount: Int) {
        var meta = metas[id] ?? ListMeta()
        meta.enabled = lists.first(where: { $0.id == id })?.isEnabled ?? meta.enabled
        meta.lastUpdated = lastUpdated
        meta.ruleCount = ruleCount
        metas[id] = meta
        saveMeta()
    }

    private func saveMeta() {
        DiskStore.save(metas, key: metaKey)
    }
}
