import Foundation

enum AgentMessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct AgentMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: AgentMessageRole
    var content: String?
    var toolCalls: [AgentToolCall]?
    var toolCallId: String?
    var toolName: String?
    /// User-attached images as JPEG data URIs (vision models only; stripped
    /// before persistence so conversation files stay small). Optional, so
    /// conversations saved before this field existed still decode.
    var imageDataURIs: [String]?
    let createdAt: Date

    init(role: AgentMessageRole, content: String? = nil, toolCalls: [AgentToolCall]? = nil, toolCallId: String? = nil, toolName: String? = nil, images: [String]? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.imageDataURIs = images
        self.createdAt = Date()
    }
}
