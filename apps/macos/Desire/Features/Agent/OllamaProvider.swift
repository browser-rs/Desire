import Foundation

/// Local model provider talking to an [Ollama](https://ollama.com) server
/// via its OpenAI-compatible endpoint (`/v1/chat/completions`).
///
/// Ollama runs entirely on the user's machine — no API key, no network
/// egress, full privacy. The server exposes the same streaming
/// Chat Completions protocol as OpenAI, including tool calling, so this
/// provider reuses `OpenAICompatSSE` for response parsing and differs from
/// `CloudOpenAIProvider` only in request construction:
///
/// - No `Authorization` header (Ollama ignores it).
/// - Endpoint defaults to `http://localhost:11434/v1`, configurable via
///   `AgentPreferenceStore.ollamaHost`.
/// - Model name is read from `AgentPreferenceStore.ollamaModel`
///   (e.g. `llama3.2`, `qwen2.5`, `mistral`).
///
/// The user must have Ollama installed and the chosen model pulled
/// (`ollama pull llama3.2`) before this provider can respond.
struct OllamaProvider: ModelProvider {
    func stream(
        messages: [AgentMessage],
        tools: [AgentToolDef],
        prefs: AgentPreferenceStore
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let base = prefs.ollamaHost
                let urlStr = base.hasSuffix("/chat/completions")
                    ? base : base + "/chat/completions"
                guard let url = URL(string: urlStr) else {
                    continuation.finish(throwing: AgentServiceError.network(NSError(
                        domain: "AI", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama host URL: \(base)"]
                    )))
                    return
                }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // No Authorization header — Ollama's compat endpoint doesn't
                // require one. (A dummy key would also work; omitting is cleaner.)
                // Give localhost requests a slightly longer timeout since local
                // inference can be slower than a cloud API on first token.
                req.timeoutInterval = 120
                req.httpBody = CloudOpenAIProvider.buildBody(
                    messages: messages,
                    tools: tools,
                    model: prefs.ollamaModel,
                    maxTokens: prefs.maxTokens,
                    temperature: prefs.temperature
                )

                #if DEBUG
                CloudOpenAIProvider.logRequest(url: url, model: prefs.ollamaModel, messages: messages, tools: tools, body: req.httpBody)
                #endif

                let sse = OpenAICompatSSE.stream(for: req)
                do {
                    for try await event in sse {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
