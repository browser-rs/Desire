import Foundation

/// Tool-calling schema types for the AI conversation format (OpenAI-style
/// function/tool calling). Used both to send tool definitions to the model
/// (`AIToolDef`) and to parse the model's tool-invocation requests
/// (`AIToolCall`). Split out of `AIMessage.swift` so each concept has its
/// own file.

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

// `nonisolated` pure value types: their Codable conformances are used from
// nonisolated encoding helpers (OpenAICompatSSE), which a MainActor-isolated
// conformance would forbid.
nonisolated struct AIJSONSchema: Codable, Sendable {
    let type: String
    var properties: [String: AIJSONSchemaValue]?
    var required: [String]?
    var description: String?
    // DeepSeek / OpenCode Go require `additionalProperties: false` on every
    // object schema — otherwise they reject the request with
    // "Upstream request failed / invalid_request_error".
    var additionalProperties: Bool? = false
}

nonisolated struct AIJSONSchemaValue: Codable, Sendable {
    let type: String
    var description: String?
    /// Nested object properties — MCP tool schemas are arbitrarily deep,
    /// so the value type must recurse (arrays/dicts break the recursion).
    var properties: [String: AIJSONSchemaValue]?
    var required: [String]?
}
