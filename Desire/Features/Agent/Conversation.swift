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
}
