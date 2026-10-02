import Foundation
import WebKit
import os

/// chrome.declarativeNetRequest 的宿主侧（2026-10-02）：每个插件的规则集
/// （manifest 静态 + dynamic + session）编译成**一份** WKContentRuleList，
/// 分发到全部已注册 controller（InterceptStore 同款弱引用注册表 + 迟到
/// 分发模式）。
///
/// 语义取舍（勿"修"）：
/// - session 规则只存内存（Chrome 语义：重启即清）；dynamic/静态落盘；
/// - allow 类动作映射 ignore-previous-rules 且**排在规则集最后**（见
///   DNRConverter.convert 的排序注释）；
/// - modifyHeaders/requestDomains 等表达不了的规则逐条丢弃带理由，不整包
///   失败——编译失败的规则经二分自愈剔除（FilterListStore.sanitize 同款）。
@MainActor
final class PluginDNRStore {
    static let shared = PluginDNRStore()
    static let log = Log.userScripts

    /// 单插件规则上限（真实广告拦截列表 3-5 万条，留足余量）。
    nonisolated private static let maxRulesPerPlugin = 60_000

    private struct Entry: Codable {
        let pluginID: UUID
        var rules: [DNRRule]
    }

    private var dynamicRules: [UUID: [DNRRule]] = [:]
    private var sessionRules: [UUID: [DNRRule]] = [:]
    private var staticRules: [UUID: [DNRRule]] = [:]
    private var compiled: [UUID: WKContentRuleList] = [:]
    /// 最近一次编译的丢弃清单（桥 /plugins/dnr 诊断用）。
    private(set) var droppedDiagnostics: [UUID: [String]] = [:]

    private struct WeakController { weak var controller: WKUserContentController? }
    private var registered: [WeakController] = []
    private var addedPerController: [ObjectIdentifier: [(pluginID: UUID, list: WKContentRuleList)]] = [:]

    private static let dynamicKey = "plugin.dnr.dynamic"
    private static let staticKey = "plugin.dnr.static"

    private init() {
        let dynamic = DiskStore.load([Entry].self, key: Self.dynamicKey) ?? []
        for entry in dynamic { dynamicRules[entry.pluginID] = entry.rules }
        let staticEntries = DiskStore.load([Entry].self, key: Self.staticKey) ?? []
        for entry in staticEntries { staticRules[entry.pluginID] = entry.rules }
        for pluginID in Set(dynamicRules.keys).union(staticRules.keys) {
            recompile(pluginID: pluginID)
        }
    }

    // MARK: - 生命周期

    /// 插件卸载/停用清场（PluginStore.remove 调用；停用保留规则——重启用）。
    func removeAll(pluginID: UUID) {
        dynamicRules.removeValue(forKey: pluginID)
        sessionRules.removeValue(forKey: pluginID)
        staticRules.removeValue(forKey: pluginID)
        droppedDiagnostics.removeValue(forKey: pluginID)
        savePersisted()
        removeEverywhere(pluginID: pluginID)
        discardStoredList(pluginID: pluginID)
    }

    /// manifest 静态规则（MSExInstaller 装载时调用；重装 = 替换）。
    func setStaticRules(pluginID: UUID, rules: [DNRRule]) {
        staticRules[pluginID] = rules
        savePersisted()
        recompile(pluginID: pluginID)
    }

    /// 桥 /plugins/dnr 诊断。
    func diagnostics(pluginID: UUID) -> [String: Any] {
        ["static": staticRules[pluginID]?.count ?? 0,
         "dynamic": dynamicRules[pluginID]?.count ?? 0,
         "session": sessionRules[pluginID]?.count ?? 0,
         "compiled": compiled[pluginID] != nil,
         "dropped": droppedDiagnostics[pluginID] ?? []]
    }

    // MARK: - chrome.declarativeNetRequest

    func getRules(pluginID: UUID, session: Bool) -> [DNRRule] {
        (session ? sessionRules[pluginID] : dynamicRules[pluginID]) ?? []
    }

    /// updateDynamicRules / updateSessionRules。校验失败抛错（→ promise reject，
    /// 语义对齐 Chrome 的 lastError）。先移除后添加（同一 id 先删再加 = 合法）。
    func updateRules(pluginID: UUID, add: [DNRRule], removeIds: [Int], session: Bool) throws {
        guard add.count <= Self.maxRulesPerPlugin else {
            throw DNRError.tooMany(add.count)
        }
        var seen = Set<Int>()
        for rule in add {
            guard rule.id > 0 else { throw DNRError.badID(rule.id) }
            guard seen.insert(rule.id).inserted else {
                throw DNRError.duplicateID(rule.id)
            }
        }
        var target = (session ? sessionRules[pluginID] : dynamicRules[pluginID]) ?? []
        target.removeAll { removeIds.contains($0.id) }
        let existing = Set(target.map(\.id))
        for rule in add where existing.contains(rule.id) {
            throw DNRError.duplicateID(rule.id)
        }
        let mergedCount = target.count + add.count
            + (session ? (dynamicRules[pluginID]?.count ?? 0) : (sessionRules[pluginID]?.count ?? 0))
        guard mergedCount <= Self.maxRulesPerPlugin else {
            throw DNRError.tooMany(mergedCount)
        }
        target += add
        if session {
            sessionRules[pluginID] = target
        } else {
            dynamicRules[pluginID] = target
            savePersisted()
        }
        recompile(pluginID: pluginID)
    }

    // MARK: - WebKit 分发

    func apply(to controller: WKUserContentController) {
        registered.removeAll { $0.controller == nil }
        guard !registered.contains(where: { $0.controller === controller }) else { return }
        registered.append(WeakController(controller: controller))
        for (pluginID, list) in compiled {
            controller.add(list)
            addedPerController[ObjectIdentifier(controller), default: []]
                .append((pluginID, list))
        }
    }

    private func savePersisted() {
        DiskStore.save(dynamicRules.map { Entry(pluginID: $0.key, rules: $0.value) },
                       key: Self.dynamicKey)
        DiskStore.save(staticRules.map { Entry(pluginID: $0.key, rules: $0.value) },
                       key: Self.staticKey)
    }

    private func compileKey(_ pluginID: UUID) -> String {
        "plugindnr-\(pluginID.uuidString)"
    }

    /// 合并三源规则集 → 转换 → 编译 → 分发。编译失败二分自愈（只丢坏规则）。
    private func recompile(pluginID: UUID) {
        let merged = (staticRules[pluginID] ?? [])
            + (dynamicRules[pluginID] ?? [])
            + (sessionRules[pluginID] ?? [])
        guard let store = FilterListStore.ruleListStore() else { return }
        let identifier = compileKey(pluginID)

        guard !merged.isEmpty else {
            removeEverywhere(pluginID: pluginID)
            discardStoredList(pluginID: pluginID)
            compiled.removeValue(forKey: pluginID)
            droppedDiagnostics.removeValue(forKey: pluginID)
            return
        }

        let outcome = DNRConverter.convert(merged)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (kept, dropped) = await Self.sanitize(outcome.rules, store: store)
            guard !kept.isEmpty else {
                Self.log.error("dnr: all \(outcome.rules.count) rules rejected for \(pluginID.uuidString.prefix(8), privacy: .public)")
                self.removeEverywhere(pluginID: pluginID)
                self.discardStoredList(pluginID: pluginID)
                self.compiled.removeValue(forKey: pluginID)
                return
            }
            guard let data = try? JSONSerialization.data(withJSONObject: kept, options: []),
                  let source = String(data: data, encoding: .utf8) else { return }
            await Self.removeStoredList(store, identifier: identifier)
            guard let list = await Self.compileStored(store, identifier: identifier, source: source) else {
                Self.log.error("dnr: compile failed for \(pluginID.uuidString.prefix(8), privacy: .public)")
                return
            }
            self.compiled[pluginID] = list
            var reasons = outcome.dropped.map { "rule \($0.id): \($0.reason)" }
            reasons += dropped.map { "rule (id in json): \($0)" }
            self.droppedDiagnostics[pluginID] = reasons
            self.addEverywhere(pluginID: pluginID, list: list)
            Self.log.info("dnr: \(kept.count) rules live for \(pluginID.uuidString.prefix(8), privacy: .public)")
        }
    }

    private func addEverywhere(pluginID: UUID, list: WKContentRuleList) {
        removeEverywhere(pluginID: pluginID)
        for box in registered {
            guard let controller = box.controller else { continue }
            controller.add(list)
            addedPerController[ObjectIdentifier(controller), default: []]
                .append((pluginID, list))
        }
    }

    private func removeEverywhere(pluginID: UUID) {
        for box in registered {
            guard let controller = box.controller else { continue }
            let key = ObjectIdentifier(controller)
            guard var added = addedPerController[key] else { continue }
            let matched = added.filter { $0.pluginID == pluginID }
            added.removeAll { $0.pluginID == pluginID }
            addedPerController[key] = added
            for entry in matched { controller.remove(entry.list) }
        }
    }

    private func discardStoredList(pluginID: UUID) {
        FilterListStore.ruleListStore()?.removeContentRuleList(
            forIdentifier: compileKey(pluginID)) { _ in }
    }

    // MARK: - 编译自愈

    /// 二分自愈：整包编译失败 → 对半递归，只保留能编译的规则
    ///（FilterListStore.sanitize 同款策略，作用于 content-blocker JSON 数组）。
    private static func sanitize(_ rules: [[String: Any]],
                                 store: WKContentRuleListStore) async -> (kept: [[String: Any]], dropped: [[String: Any]]) {
        guard !rules.isEmpty else { return ([], []) }
        if await tryCompile(rules, store: store) != nil { return (rules, []) }
        if rules.count == 1 { return ([], rules) }
        let mid = rules.count / 2
        let head = await sanitize(Array(rules[..<mid]), store: store)
        let tail = await sanitize(Array(rules[mid...]), store: store)
        return (head.kept + tail.kept, head.dropped + tail.dropped)
    }

    /// 用一次性随机 identifier 试编译（不污染正式 identifier 的存储槽）。
    private static func tryCompile(_ rules: [[String: Any]],
                                   store: WKContentRuleListStore) async -> WKContentRuleList? {
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
              let source = String(data: data, encoding: .utf8) else { return nil }
        let probeID = "probe-\(UUID().uuidString)"
        return await compileStored(store, identifier: probeID, source: source)
    }

    /// 正式编译（async 包装——嵌套回调里的 weak/strong 捕获错配是警告源）。
    private static func compileStored(_ store: WKContentRuleListStore,
                                      identifier: String, source: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private static func removeStoredList(_ store: WKContentRuleListStore, identifier: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }

    enum DNRError: LocalizedError {
        case tooMany(Int)
        case badID(Int)
        case duplicateID(Int)

        var errorDescription: String? {
            switch self {
            case .tooMany(let count):
                "Too many rules (\(count), cap \(maxRulesPerPlugin))"
            case .badID(let id):
                "Invalid rule id \(id) (must be a positive integer)"
            case .duplicateID(let id):
                "A rule with id \(id) already exists"
            }
        }
    }
}
