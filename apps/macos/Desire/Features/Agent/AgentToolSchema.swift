import Foundation

/// Tool-calling schema types for the AI conversation format (OpenAI-style
/// function/tool calling). Used both to send tool definitions to the model
/// (`AgentToolDef`) and to parse the model's tool-invocation requests
/// (`AgentToolCall`). Split out of `AgentMessage.swift` so each concept has its
/// own file.

struct AgentToolCall: Identifiable, Codable, Sendable {
    let id: String
    let type: String
    let function: AgentToolFunction
}

struct AgentToolFunction: Codable, Sendable {
    let name: String
    let arguments: String
}

struct AgentToolDef: Codable, Sendable {
    let type: String
    let function: AgentToolFunctionDef
}

struct AgentToolFunctionDef: Codable, Sendable {
    let name: String
    let description: String
    let parameters: AgentJSONSchema
}

// `nonisolated` pure value types: their Codable conformances are used from
// nonisolated encoding helpers (OpenAICompatSSE), which a MainActor-isolated
// conformance would forbid.
nonisolated struct AgentJSONSchema: Codable, Sendable {
    let type: String
    var properties: [String: AgentJSONSchemaValue]?
    var required: [String]?
    var description: String?
    // DeepSeek / OpenCode Go require `additionalProperties: false` on every
    // object schema — otherwise they reject the request with
    // "Upstream request failed / invalid_request_error".
    var additionalProperties: Bool? = false
}

nonisolated struct AgentJSONSchemaValue: Codable, Sendable {
    let type: String
    var description: String?
    /// Nested object properties — MCP tool schemas are arbitrarily deep,
    /// so the value type must recurse (arrays/dicts break the recursion).
    var properties: [String: AgentJSONSchemaValue]?
    var required: [String]?
    /// Element schema for `type: "array"` values (e.g. pressKey modifiers).
    /// Boxed in a class: a value type cannot recursively contain itself.
    var items: JSONSchemaItemBox?
}

/// Reference box that makes `AgentJSONSchemaValue.items` legal while
/// encoding/decoding transparently AS the inner schema (`items: {…}` —
/// the standard JSON-Schema shape, not `items: {value: {…}}`).
final class JSONSchemaItemBox: Codable, @unchecked Sendable {
    let value: AgentJSONSchemaValue

    init(value: AgentJSONSchemaValue) { self.value = value }

    required init(from decoder: Decoder) throws {
        value = try AgentJSONSchemaValue(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
