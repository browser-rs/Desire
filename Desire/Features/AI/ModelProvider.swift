import Foundation

/// Abstraction over a chat-completion model backend.
///
/// Desire supports multiple model sources (cloud OpenAI-compatible APIs,
/// Apple Foundation Models on-device, local Ollama, and a rule-based
/// `RoutingProvider` that picks among them). Every source conforms to this
/// protocol so `AISessionStore` can drive an agent loop without knowing
/// where the tokens come from.
///
/// The contract intentionally mirrors the OpenAI streaming tool-call shape:
/// a stream of incremental text deltas and/or a terminal `AIToolCall`.
/// Each concrete provider is responsible for translating its native format
/// into these events.
///
/// Concurrency: implementations are `Sendable`-safe because the only
/// captured state (`AIPreferenceStore`) is a `@MainActor` value type read
/// once before the request fires.
protocol ModelProvider {
    /// Stream a completion for the given conversation, optionally exposing
    /// `tools` the model may call.
    ///
    /// - Parameters:
    ///   - messages: Full conversation history (user/assistant/tool roles).
    ///   - tools: Tool definitions the model is allowed to invoke. Empty
    ///     means "text-only response".
    ///   - prefs: User-configured model settings (endpoint, key, temperature…).
    /// - Returns: An `AsyncThrowingStream` that yields `.text(String)` deltas
    ///   and `.toolCall(AIToolCall)` events, then finishes. Errors are thrown
    ///   through the stream's terminator.
    func stream(
        messages: [AIMessage],
        tools: [AIToolDef],
        prefs: AIPreferenceStore
    ) -> AsyncThrowingStream<AIStreamEvent, Error>
}

/// Streaming events emitted by a `ModelProvider` while generating a response.
enum AIStreamEvent {
    case text(String)
    case toolCall(AIToolCall)
}

/// Errors surfaced by `ModelProvider` implementations.
enum AIServiceError: LocalizedError {
    case noAPIKey
    case network(Error)
    case decoding(Error)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "API Key not configured. Set it in Settings > AI."
        case .network(let e): return "Network error: \(e.localizedDescription)"
        case .decoding(let e): return "Response parsing error: \(e.localizedDescription)"
        case .httpStatus(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        }
    }
}
