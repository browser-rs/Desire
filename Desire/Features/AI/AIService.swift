import Foundation

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

                let bodyDict: [String: Any] = [
                    "model": prefs.model,
                    "messages": messages.map(Self.encodeMessage),
                    "stream": true,
                    "max_tokens": prefs.maxTokens,
                    "temperature": prefs.temperature,
                ]

                var body: [String: Any] = bodyDict
                if !tools.isEmpty {
                    body["tools"] = tools.map { t in
                        [
                            "type": t.type,
                            "function": [
                                "name": t.function.name,
                                "description": t.function.description,
                                "parameters": Self.encodeJSONSchema(t.function.parameters),
                            ],
                        ]
                    }
                }

                req.httpBody = try? JSONSerialization.data(withJSONObject: body)

                #if DEBUG
                // Diagnostic: log the exact request body to help debug
                // 400 "Upstream request failed" errors from OpenCode Go.
                if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: data, encoding: .utf8) {
                    print("──── AI request body ────")
                    print("Endpoint: \(url.absoluteString)")
                    print("Model: \(prefs.model)")
                    print("Messages: \(messages.count)")
                    for (i, msg) in messages.enumerated() {
                        print("  [\(i)] role=\(msg.role.rawValue), hasContent=\(msg.content != nil), toolCallId=\(msg.toolCallId ?? "nil"), toolName=\(msg.toolName ?? "nil")")
                    }
                    print("Tools: \(tools.count)")
                    print(s)
                    print("─────────────────────────")
                }
                #endif

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
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
                        print("URL: \(url.absoluteString)")
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

    private static func encodeMessage(_ msg: AIMessage) -> [String: Any] {
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
