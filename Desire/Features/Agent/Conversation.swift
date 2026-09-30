import Foundation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [AgentMessage]
    /// 本对话的输入历史（面板输入框 ↑/↓ 翻阅）。最新在末尾，可选字段——
    /// 旧会话文件没有它也能解码。
    var inputHistory: [String]?
    /// updatePlan 的任务清单（计划跟着会话走：切回/重启后恢复）。
    var planSteps: [AgentPlanStep]?
}
