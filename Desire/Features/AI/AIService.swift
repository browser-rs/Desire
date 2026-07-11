import Foundation

/// Shared OpenAI-compatible streaming client.
///
/// Both `CloudOpenAIProvider` (OpenAI / OpenRouter / LiteLLM / DeepSeek / …)
/// and `OllamaProvider` (local `http://localhost:11434/v1`) speak the same
/// Chat Completions SSE protocol. The only differences are request
/// construction (auth header, endpoint). This enum owns the response parsing
/// so neither provider duplicates the ~80-line SSE loop.
enum OpenAICompatSSE {
    /// Drives a streaming Chat Completions request built by the caller.
    ///
    /// - Assumes `request` already has method/body/headers set.
    /// - Yields `.text` deltas and `.toolCall` events as they arrive.
    static func stream(for request: URLRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AIServiceError.network(NSError(domain: "AI", code: -1)))
                        return
                    }
                    guard http.statusCode == 200 else {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line }
                        #if DEBUG
                        print("──── AI request failed ────")
                        print("Status: \(http.statusCode)")
                        print("URL: \(request.url?.absoluteString ?? "?")")
                        print("Response: \(errBody)")
                        print("──────────────────────────")
                        #endif
                        continuation.finish(throwing: AIServiceError.httpStatus(http.statusCode, errBody))
                        return
                    }

                    var toolCallID = ""
                    var toolCallName = ""
                    var toolCallArgs = ""
                    var hasToolCall = false

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))
                        if data == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let choice = choices.first,
                              let delta = choice["delta"] as? [String: Any] else { continue }

                        if let text = delta["content"] as? String {
                            continuation.yield(.text(text))
                        }

                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for tc in toolCalls {
                                let idx = tc["index"] as? Int ?? 0
                                if idx == 0 {
                                    if let id = tc["id"] as? String {
                                        toolCallID = id
                                        hasToolCall = true
                                    }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let name = fn["name"] as? String, !name.isEmpty {
                                            toolCallName += name
                                        }
                                        if let args = fn["arguments"] as? String {
                                            toolCallArgs += args
                                        }
                                    }
                                }
                            }
                        }

                        if let finishReason = choice["finish_reason"] as? String,
                           finishReason == "tool_calls", hasToolCall {
                            let call = AIToolCall(
                                id: toolCallID,
                                type: "function",
                                function: AIToolFunction(name: toolCallName, arguments: toolCallArgs)
                            )
                            continuation.yield(.toolCall(call))
                            toolCallID = ""; toolCallName = ""; toolCallArgs = ""; hasToolCall = false
                        }
                    }

                    if hasToolCall {
                        let call = AIToolCall(
                            id: toolCallID,
                            type: "function",
                            function: AIToolFunction(name: toolCallName, arguments: toolCallArgs)
                        )
                        continuation.yield(.toolCall(call))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIServiceError.network(error))
                }
            }
        }
    }

    /// Encodes an `AIMessage` to the OpenAI chat message dict shape, including
    /// `tool_calls` and `tool_call_id`/`name` fields for tool-use turns.
    static func encodeMessage(_ msg: AIMessage) -> [String: Any] {
        var m: [String: Any] = ["role": msg.role.rawValue]
        if let content = msg.content { m["content"] = content }
        if let tcs = msg.toolCalls {
            m["tool_calls"] = tcs.map { tc in
                [
                    "id": tc.id,
                    "type": tc.type,
                    "function": [
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    ],
                ]
            }
        }
        if let tid = msg.toolCallId {
            m["tool_call_id"] = tid
            // OpenCode Go (and several OpenAI-compatible proxies) require
            // the `name` field on tool messages — the function name that
            // produced this result. Without it they 400 with
            // "invalid_request_error / Upstream request failed" on the
            // second turn of a tool-use conversation.
            if let name = msg.toolName {
                m["name"] = name
            }
        }
        return m
    }

    /// Encodes a tool definition to the OpenAI `tools` array shape.
    static func encodeTool(_ t: AIToolDef) -> [String: Any] {
        [
            "type": t.type,
            "function": [
                "name": t.function.name,
                "description": t.function.description,
                "parameters": encodeJSONSchema(t.function.parameters),
            ],
        ]
    }

    // `AIJSONSchema` is a Swift `Codable` struct, not an `[String: Any]`,
    // so JSONSerialization refuses to encode it ("Invalid type in JSON
    // write __SwiftValue"). Round-trip through `JSONEncoder` to get a real
    // dictionary we can hand to JSONSerialization.
    private static func encodeJSONSchema(_ schema: AIJSONSchema) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(schema),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }
}

/// Cloud model provider speaking the OpenAI Chat Completions streaming
/// protocol. Works with OpenAI directly and any compatible proxy
/// (OpenRouter, LiteLLM, OpenCode Go, DeepSeek, Together, …).
///
/// History note: this type was previously `struct AIService` with a single
/// `static func stream(...)`. It has been renamed to `CloudOpenAIProvider`
/// and conforms to `ModelProvider` so the agent loop can swap providers.
/// The `AIService` typealias below keeps any external references compiling.
struct CloudOpenAIProvider: ModelProvider {
    func stream(
        messages: [AIMessage],
        tools: [AIToolDef],
        prefs: AIPreferenceStore
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let apiKey = prefs.loadAPIKey() else {
                    continuation.finish(throwing: AIServiceError.noAPIKey)
                    return
                }

                let urlStr = prefs.endpoint.hasSuffix("/chat/completions")
                    ? prefs.endpoint : prefs.endpoint + "/chat/completions"
                guard let url = URL(string: urlStr) else {
                    continuation.finish(throwing: AIServiceError.network(NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])))
                    return
                }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("chatcmpl-\(String(UUID().uuidString.prefix(8)))", forHTTPHeaderField: "X-Request-Id")
                req.httpBody = Self.buildBody(messages: messages, tools: tools, model: prefs.model, maxTokens: prefs.maxTokens, temperature: prefs.temperature)

                #if DEBUG
                Self.debugLogRequest(url: url, model: prefs.model, messages: messages, tools: tools, body: req.httpBody)
                #endif

                let sse = OpenAICompatSSE.stream(for: req)
                do {
                    for try await event in sse {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func buildBody(messages: [AIMessage], tools: [AIToolDef], model: String, maxTokens: Int, temperature: Double) -> Data? {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(OpenAICompatSSE.encodeMessage),
            "stream": true,
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(OpenAICompatSSE.encodeTool)
        }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    #if DEBUG
    static func debugLogRequest(url: URL, model: String, messages: [AIMessage], tools: [AIToolDef], body: Data?) {
        print("──── AI request body ────")
        print("Endpoint: \(url.absoluteString)")
        print("Model: \(model)")
        print("Messages: \(messages.count)")
        for (i, msg) in messages.enumerated() {
            print("  [\(i)] role=\(msg.role.rawValue), hasContent=\(msg.content != nil), toolCallId=\(msg.toolCallId ?? "nil"), toolName=\(msg.toolName ?? "nil")")
        }
        print("Tools: \(tools.count)")
        if let data = body,
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: pretty, encoding: .utf8) {
            print(s)
        }
        print("─────────────────────────")
    }
    #endif
}

/// Backward-compatibility facade. Existing call sites that referenced
/// `AIService.stream(...)` continue to work, delegating to the default
/// cloud provider. New code should go through `ModelProvider` / the
/// `provider` on `AIPreferenceStore`.
enum AIService {
    static func stream(
        messages: [AIMessage],
        tools: [AIToolDef],
        prefs: AIPreferenceStore
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        CloudOpenAIProvider().stream(messages: messages, tools: tools, prefs: prefs)
    }
}
