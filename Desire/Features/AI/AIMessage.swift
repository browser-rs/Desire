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

struct AIToolCall: Identifiable, Codable, Sendable {
    let id: String
    let type: String
    let function: AIToolFunction
}

struct AIToolFunction: Codable, Sendable {
    let name: String
    let arguments: String
}

struct AIToolDef: Codable, Sendable {
    let type: String
    let function: AIToolFunctionDef
}

struct AIToolFunctionDef: Codable, Sendable {
    let name: String
    let description: String
    let parameters: AIJSONSchema
}

struct AIJSONSchema: Codable, Sendable {
    let type: String
    var properties: [String: AIJSONSchemaValue]?
    var required: [String]?
    var description: String?
    // DeepSeek / OpenCode Go require `additionalProperties: false` on every
    // object schema — otherwise they reject the request with
    // "Upstream request failed / invalid_request_error".
    var additionalProperties: Bool? = false
}

struct AIJSONSchemaValue: Codable, Sendable {
    let type: String
    var description: String?
}
