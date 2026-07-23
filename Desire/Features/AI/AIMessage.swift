import Foundation

enum AIMessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct AIMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: AIMessageRole
    var content: String?
    var toolCalls: [AIToolCall]?
    var toolCallId: String?
    var toolName: String?
    let createdAt: Date

    init(role: AIMessageRole, content: String? = nil, toolCalls: [AIToolCall]? = nil, toolCallId: String? = nil, toolName: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.createdAt = Date()
    }
}
