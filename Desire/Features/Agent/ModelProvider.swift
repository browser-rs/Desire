import Foundation

/// Abstraction over a chat-completion model backend.
///
/// Desire supports multiple model sources (cloud OpenAI-compatible APIs,
/// Apple Foundation Models on-device, local Ollama, and a rule-based
/// `RoutingProvider` that picks among them). Every source conforms to this
/// protocol so `AgentSessionStore` can drive an agent loop without knowing
/// where the tokens come from.
///
/// The contract intentionally mirrors the OpenAI streaming tool-call shape:
/// a stream of incremental text deltas and/or a terminal `AgentToolCall`.
/// Each concrete provider is responsible for translating its native format
/// into these events.
///
/// Concurrency: implementations are `Sendable`-safe because the only
/// captured state (`AgentPreferenceStore`) is a `@MainActor` value type read
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
    ///   and `.toolCall(AgentToolCall)` events, then finishes. Errors are thrown
    ///   through the stream's terminator.
    func stream(
        messages: [AgentMessage],
        tools: [AgentToolDef],
        prefs: AgentPreferenceStore
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

/// Streaming events emitted by a `ModelProvider` while generating a response.
enum AgentStreamEvent {
    case text(String)
    /// 推理模型的思考增量（`reasoning_content` / `reasoning` / `thinking`）。
    case reasoning(String)
    case toolCall(AgentToolCall)
    /// Provider-reported token usage for this call (best-effort — most
    /// OpenAI-compatible backends send it in the final chunk; Foundation
    /// Models reports nothing).
    case usage(promptTokens: Int, completionTokens: Int)
    /// 服务端自报的模型 id（响应里的 `model`）。**实际跑的**模型可能与请求里选的
    /// 不同（网关会路由/改写：选了 `main-model` 实际跑某个上游模型），成本得按真跑的
    /// 那个算；服务端不给就由调用方退回"请求时选的模型"。
    case model(String)
}

/// Errors surfaced by `ModelProvider` implementations.
enum AgentServiceError: LocalizedError {
    case noAPIKey
    case network(Error)
    case decoding(Error)
    case httpStatus(Int, String)
    /// The chosen model backend is not usable right now — e.g. Apple
    /// Intelligence not enabled, or the device is ineligible. The caller
    /// should hint the user to switch provider or enable the prerequisite.
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "API Key not configured. Set it in Settings > Agent."
        case .network(let e): return "Network error: \(e.localizedDescription)"
        case .decoding(let e): return "Response parsing error: \(e.localizedDescription)"
        case .httpStatus(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .modelUnavailable(let reason): return "Model unavailable: \(reason)"
        }
    }
}
