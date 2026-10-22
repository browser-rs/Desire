import Foundation

/// 审批历史日志：每次工具审批决策记录一条（持久化最近 200 条）。
struct ApprovalHistoryEntry: Codable, Identifiable {
    let id: UUID
    var toolName: String
    /// 站点维度（0.8.1）：审批时的页面 host；nil = 与站点无关。
    var host: String?
    var decision: String
    var source: String // ui | bridge | policy | hook | …
    var createdAt: Date
}
