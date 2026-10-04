import Combine
import Foundation

/// 审批策略引擎（0.2.6）：持久化的按工具名放行/拒绝规则。与内置白名单
/// （AgentPreferenceStore.allowedTools）的区别：这里支持 deny 规则和
/// 永久拒绝（连 dangerous 工具也会被拒），且规则从桥可管理。
struct ApprovalPolicy: Codable, Identifiable, Equatable {
    let id: UUID
    /// 工具名（精确匹配）。
    var toolName: String
    var decision: Decision
    var createdAt: Date

    enum Decision: String, Codable {
        case allow
        case deny
    }
}

/// 审批历史日志：每次工具审批决策记录一条（持久化最近 200 条）。
struct ApprovalHistoryEntry: Codable, Identifiable {
    let id: UUID
    var toolName: String
    var decision: String
    var source: String // ui | bridge | policy
    var createdAt: Date
}

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

    /// Returns the effective decision for a tool, or nil when no rule matches.
    func decision(for toolName: String) -> ApprovalPolicy.Decision? {
        rules.first(where: { $0.toolName == toolName })?.decision
    }

    @discardableResult
    func addRule(toolName: String, decision: ApprovalPolicy.Decision) -> ApprovalPolicy? {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 同工具已有规则则更新决策（幂等）。
        if let idx = rules.firstIndex(where: { $0.toolName == trimmed }) {
            rules[idx].decision = decision
            saveRules()
            return rules[idx]
        }
        let rule = ApprovalPolicy(id: UUID(), toolName: trimmed, decision: decision, createdAt: Date())
        rules.append(rule)
        saveRules()
        return rule
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        saveRules()
    }

    func clearRules() {
        rules.removeAll()
        saveRules()
    }

    // MARK: - History

    func recordHistory(toolName: String, decision: String, source: String) {
        let entry = ApprovalHistoryEntry(
            id: UUID(), toolName: toolName, decision: decision,
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
