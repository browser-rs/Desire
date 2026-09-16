import Foundation
import os

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
    static func stream(for request: URLRequest) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AgentServiceError.network(NSError(domain: "AI", code: -1)))
                        return
                    }
                    guard http.statusCode == 200 else {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line }
                        #if DEBUG
                        Log.ai.error("AI request failed — status: \(http.statusCode, privacy: .public), url: \(request.url?.absoluteString ?? "?", privacy: .public), body: \(errBody)")
                        #endif
                        continuation.finish(throwing: AgentServiceError.httpStatus(http.statusCode, errBody))
                        return
                    }

                    // A single assistant turn can carry MULTIPLE parallel
                    // tool calls ("open three tabs and check each"); their
                    // deltas arrive interleaved, keyed by `index`. The old
                    // accumulator only kept index 0, silently dropping every
                    // call after the first. Track one partial per index and
                    // flush them all in first-seen order.
                    var partials: [Int: (id: String, name: String, arguments: String)] = [:]
                    var order: [Int] = []

                    func flushToolCalls() {
                        for idx in order {
                            let p = partials[idx] ?? (id: "", name: "", arguments: "")
                            // Some OpenAI-compatible servers (older Ollama)
                            // omit ids; the agent loop correlates tool
                            // results by id, so synthesize a unique one.
                            let id = p.id.isEmpty
                                ? "call_\(idx)_\(UUID().uuidString.prefix(8))"
                                : p.id
                            continuation.yield(.toolCall(AgentToolCall(
                                id: id,
                                type: "function",
                                function: AgentToolFunction(name: p.name, arguments: p.arguments)
                            )))
                        }
                        partials.removeAll()
                        order.removeAll()
                    }

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
                                if partials[idx] == nil {
                                    partials[idx] = (id: "", name: "", arguments: "")
                                    order.append(idx)
                                }
                                var p = partials[idx]!
                                if let id = tc["id"] as? String, !id.isEmpty { p.id = id }
                                if let fn = tc["function"] as? [String: Any] {
                                    if let name = fn["name"] as? String, !name.isEmpty { p.name += name }
                                    if let args = fn["arguments"] as? String { p.arguments += args }
                                }
                                partials[idx] = p
                            }
                        }

                        if let finishReason = choice["finish_reason"] as? String,
                           finishReason == "tool_calls" {
                            flushToolCalls()
                        }
                    }

                    // Some servers end the stream without finish_reason.
                    flushToolCalls()

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AgentServiceError.network(error))
                }
            }
        }
    }

    /// Encodes an `AgentMessage` to the OpenAI chat message dict shape, including
    /// `tool_calls` and `tool_call_id`/`name` fields for tool-use turns.
    ///
    /// Pure encoding helper with no shared state — `nonisolated` so callers
    /// from any isolation domain can use it without hopping actors.
    nonisolated static func encodeMessage(_ msg: AgentMessage) -> [String: Any] {
        var m: [String: Any] = ["role": msg.role.rawValue]
        // Multimodal turns: user-attached images and screenshot tool results
        // are encoded as a content array so vision models can see them.
        if let images = msg.imageDataURIs, !images.isEmpty, msg.role == .user {
            var parts: [[String: Any]] = []
            if let text = msg.content, !text.isEmpty {
                parts.append(["type": "text", "text": text])
            }
            for uri in images {
                parts.append(["type": "image_url", "image_url": ["url": uri]])
            }
            m["content"] = parts
        } else if msg.role == .tool, msg.toolName == "screenshot",
           let content = msg.content, content.hasPrefix("data:image/") {
            m["content"] = [
                ["type": "text", "text": "Screenshot of the current viewport"],
                ["type": "image_url", "image_url": ["url": content]],
            ]
        } else if let content = msg.content {
            m["content"] = content
        }
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

    /// Encodes a tool definition to the OpenAI `tools` array shape. Pure —
    /// see `encodeMessage` for the `nonisolated` rationale.
    nonisolated static func encodeTool(_ t: AgentToolDef) -> [String: Any] {
        [
            "type": t.type,
            "function": [
                "name": t.function.name,
                "description": t.function.description,
                "parameters": encodeJSONSchema(t.function.parameters),
            ],
        ]
    }

    // `AgentJSONSchema` is a Swift `Codable` struct, not an `[String: Any]`,
    // so JSONSerialization refuses to encode it ("Invalid type in JSON
    // write __SwiftValue"). Round-trip through `JSONEncoder` to get a real
    // dictionary we can hand to JSONSerialization.
    private nonisolated static func encodeJSONSchema(_ schema: AgentJSONSchema) -> [String: Any] {
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
/// History note: this type was previously `struct AgentService` with a single
/// `static func stream(...)`. It has been renamed to `CloudOpenAIProvider`
/// and conforms to `ModelProvider` so the agent loop can swap providers.
/// The `AgentService` typealias below keeps any external references compiling.
struct CloudOpenAIProvider: ModelProvider {
    func stream(
        messages: [AgentMessage],
        tools: [AgentToolDef],
        prefs: AgentPreferenceStore
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let apiKey = prefs.loadAPIKey() else {
                    continuation.finish(throwing: AgentServiceError.noAPIKey)
                    return
                }

                let urlStr = prefs.endpoint.hasSuffix("/chat/completions")
                    ? prefs.endpoint : prefs.endpoint + "/chat/completions"
                guard let url = URL(string: urlStr) else {
                    continuation.finish(throwing: AgentServiceError.network(NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])))
                    return
                }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("chatcmpl-\(String(UUID().uuidString.prefix(8)))", forHTTPHeaderField: "X-Request-Id")

                // OpenCode Go requires a session header for request routing.
                // A stable UUID per launch is sufficient — the server uses it
                // for sticky backend selection.
                if urlStr.contains("opencode") {
                    let sessionKey = "aiOpencodeSessionID"
                    let sessionID = UserDefaults.standard.string(forKey: sessionKey)
                        ?? UUID().uuidString
                    UserDefaults.standard.set(sessionID, forKey: sessionKey)
                    req.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
                }

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

    static func buildBody(messages: [AgentMessage], tools: [AgentToolDef], model: String, maxTokens: Int, temperature: Double) -> Data? {
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
    static func debugLogRequest(url: URL, model: String, messages: [AgentMessage], tools: [AgentToolDef], body: Data?) {
        Log.ai.debug("AI request — endpoint: \(url.absoluteString, privacy: .public), model: \(model, privacy: .public), messages: \(messages.count), tools: \(tools.count)")
        if let data = body,
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: pretty, encoding: .utf8) {
            Log.ai.debug("AI request body: \(s)")
        }
    }
    #endif
}

/// Backward-compatibility facade. Existing call sites that referenced
/// `AgentService.stream(...)` continue to work, delegating to the default
/// cloud provider. New code should go through `ModelProvider` / the
/// `provider` on `AgentPreferenceStore`.
enum AgentService {
    static func stream(
        messages: [AgentMessage],
        tools: [AgentToolDef],
        prefs: AgentPreferenceStore
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        CloudOpenAIProvider().stream(messages: messages, tools: tools, prefs: prefs)
    }
}
