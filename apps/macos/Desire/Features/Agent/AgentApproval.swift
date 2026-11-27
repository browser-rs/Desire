import Foundation

/// The user's decision on a tool approval prompt. Returned by the UI.
/// Extracted from `AgentSessionStore.swift` (one-file-one-type rule).
enum ApprovalDecision {
    case allowOnce
    case alwaysAllow
    case deny
}

/// Internal outcome the agent loop acts on. Distinct from
/// `ApprovalDecision` because whitelisted / readonly tools resolve to
/// `.allowedOnce` without ever prompting the user.
enum ApprovalOutcome {
    case allowedOnce
    case allowedAlways
    case denied
}

/// 待批审批的**可持久化快照**（v0.8.80 批 3）：continuation 活不过进程，
/// 所以跨重启保留的是"当时在等什么"——工具、参数、站点与摘要。重启后由面板
/// 重新给出允许/拒绝，再续跑被打断的回合（不静默重放副作用）。
nonisolated struct PendingApprovalSnapshot: Codable, Equatable {
    var toolName: String
    var argumentsJSON: String
    var risk: String
    var summary: String
    var siteHost: String?
    var createdAt: Date = Date()
}
