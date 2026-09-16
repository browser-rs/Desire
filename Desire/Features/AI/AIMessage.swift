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
    /// User-attached images as JPEG data URIs (vision models only; stripped
    /// before persistence so conversation files stay small). Optional, so
    /// conversations saved before this field existed still decode.
    var imageDataURIs: [String]?
    let createdAt: Date

    init(role: AIMessageRole, content: String? = nil, toolCalls: [AIToolCall]? = nil, toolCallId: String? = nil, toolName: String? = nil, images: [String]? = nil) {
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
