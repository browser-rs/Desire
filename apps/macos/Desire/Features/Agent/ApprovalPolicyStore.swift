import Combine
import Foundation

/// 审批策略引擎（0.2.6）：持久化的按工具名放行/拒绝规则；0.8.1 起支持
/// 「工具 × 站点」维度（host 为 nil 时仍是全局规则）。与内置白名单
/// （AgentPreferenceStore.allowedTools）的区别：这里支持 deny 规则和
/// 永久拒绝（连 dangerous 工具也会被拒），且规则从桥可管理。
@MainActor
final class ApprovalPolicyStore: ObservableObject {
    static let shared = ApprovalPolicyStore()

    @Published private(set) var rules: [ApprovalPolicy] = []
    @Published private(set) var history: [ApprovalHistoryEntry] = []

    private static let rulesKey = "approval-policy-rules"
    private static let historyKey = "approval-policy-history"
    private static let maxHistory = 200
    private static let log = Log.agent

    private init() {
        loadAll()
    }

    private func loadAll() {
        rules = DiskStore.load([ApprovalPolicy].self, key: Self.rulesKey) ?? []
        history = DiskStore.load([ApprovalHistoryEntry].self, key: Self.historyKey) ?? []
    }

    // MARK: - Rules

    /// Returns the effective decision for a tool on the given page host,
    /// or nil when no rule matches. Host-named rules win over global ones.
    func decision(for toolName: String, host: String? = nil) -> ApprovalPolicy.Decision? {
        ApprovalPolicy.effectiveRule(in: rules, toolName: toolName, host: host)?.decision
    }

    /// The rule that `decision(for:host:)` would use (for UI/bridge display).
    func rule(for toolName: String, host: String? = nil) -> ApprovalPolicy? {
        ApprovalPolicy.effectiveRule(in: rules, toolName: toolName, host: host)
    }

    @discardableResult
    func addRule(toolName: String,
                 decision: ApprovalPolicy.Decision,
                 host: String? = nil) -> ApprovalPolicy? {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let site = ApprovalPolicy.normalizeHost(host)
        // 同（工具, 站点）已有规则则更新决策（幂等）。
        if let idx = rules.firstIndex(where: { $0.toolName == trimmed && $0.host == site }) {
            rules[idx].decision = decision
            saveRules()
            return rules[idx]
        }
        let rule = ApprovalPolicy(toolName: trimmed, host: site,
                                  decision: decision, createdAt: Date())
        rules.append(rule)
        saveRules()
        return rule
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        saveRules()
    }

    /// 桥/设置页按（工具, 站点）吊销；host 省略只删全局规则。
    @discardableResult
    func removeRules(toolName: String, host: String? = nil) -> Bool {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = ApprovalPolicy.normalizeHost(host)
        let before = rules.count
        rules.removeAll { $0.toolName == trimmed && $0.host == site }
        guard rules.count != before else { return false }
        saveRules()
        return true
    }

    func clearRules() {
        rules.removeAll()
        saveRules()
    }

    // MARK: - History

    func recordHistory(toolName: String, decision: String, source: String,
                       host: String? = nil) {
        let entry = ApprovalHistoryEntry(
            id: UUID(), toolName: toolName,
            host: ApprovalPolicy.normalizeHost(host), decision: decision,
            source: source, createdAt: Date())
        history.insert(entry, at: 0)
        if history.count > Self.maxHistory {
            history = Array(history.prefix(Self.maxHistory))
        }
        saveHistory()
    }

    private func saveHistory() {
        DiskStore.save(history, key: Self.historyKey)
    }

    private func saveRules() {
        DiskStore.save(rules, key: Self.rulesKey)
    }

}
