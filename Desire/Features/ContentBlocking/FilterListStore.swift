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
        guard let store = WKContentRuleListStore.default() else { return }
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
        guard let store = WKContentRuleListStore.default() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }

    private func compile(id: String, abp: String) async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        let identifier = Self.ruleListIdentifier(id)
        await removeStoredList(identifier)
        let full = ABPRuleConverter.convert(abp, includeHiding: true)
        if let compiledList = try? await store.compileContentRuleList(forIdentifier: identifier,
                                                                      encodedContentRuleList: full.json) {
            return compiledList
        }
        Log.contentBlocking.error("filter list \(id, privacy: .public) full compile failed — retrying blocking-only")
        await removeStoredList(identifier)
        let blockingOnly = ABPRuleConverter.convert(abp, includeHiding: false)
        return try? await store.compileContentRuleList(forIdentifier: identifier,
                                                       encodedContentRuleList: blockingOnly.json)
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
