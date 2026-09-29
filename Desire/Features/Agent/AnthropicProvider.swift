import Foundation
import os

/// Anthropic Messages API (`/v1/messages`) provider — the second mainstream
/// wire format beside OpenAI Chat Completions.
///
/// Mirrors `CloudOpenAIProvider`/`OpenAICompatSSE` but speaks Anthropic's
/// dialect: `system` is top-level (not a message), tool calls are `tool_use`
/// blocks in the assistant turn, tool results are `tool_result` blocks inside
/// the following **user** turn (roles must strictly alternate), and the SSE
/// stream is a series of typed events (`message_start`, `content_block_delta`,
/// `message_delta`, …) instead of OpenAI's choice-delta chunks. All of that
/// translates into the same `AgentStreamEvent` vocabulary the agent loop
/// already consumes, so the turn machinery needs zero changes.
enum AnthropicSSE {

    /// Anthropic's extended-thinking budgets per app effort level. The API
    /// requires `max_tokens` > `budget_tokens`, so the body builder bumps it.
    nonisolated static func thinkingBudget(for effort: String) -> Int? {
        switch effort {
        case "low": return 4_096
        case "medium": return 10_240
        case "high": return 20_480
        default: return nil
        }
    }

    /// Builds the Messages API request body from the app's canonical message
    /// list (the same list the OpenAI path consumes — system at index 0,
    /// OpenAI-style `toolCalls`/`toolCallId` on messages).
    nonisolated static func buildBody(
        messages: [AgentMessage],
        tools: [AgentToolDef],
        model: String,
        maxTokens: Int,
        temperature: Double,
        reasoningEffort: String = "off"
    ) -> Data? {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
        ]

        // 扩展思考：档位 → budget_tokens。开启时 Anthropic 不接受自定义
        // temperature（必须省略或 1），且 max_tokens 必须大于 budget。
        if let budget = thinkingBudget(for: reasoningEffort) {
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            body["max_tokens"] = max(maxTokens, budget + 4_096)
        } else {
            body["max_tokens"] = maxTokens
            body["temperature"] = temperature
        }

        // system 是顶层字段，不是消息。应用不变式：system 只有一条且在最前
        // （带外备注已并入它）——防御式起见把所有 system 内容拼接。
        let systemText = messages
            .filter { $0.role == .system }
            .compactMap { $0.content }
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            body["system"] = systemText
        }

        body["messages"] = encodeMessages(messages.filter { $0.role != .system })

        if !tools.isEmpty {
            body["tools"] = tools.map(encodeTool)
        }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// Encodes the conversation to Anthropic's strictly-alternating
    /// user/assistant turns. Tool results (`role == .tool`) become
    /// `tool_result` blocks inside a **user** turn; consecutive tool results
    /// merge into that single user turn (the API requires them at the start
    /// of the message and one message per assistant tool_use batch).
    nonisolated static func encodeMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []

        func appendBlock(to index: Int, _ block: [String: Any]) {
            var content = out[index]["content"] as? [[String: Any]] ?? []
            content.append(block)
            out[index]["content"] = content
        }

        for msg in messages {
            switch msg.role {
            case .user:
                let blocks = userTextAndImageBlocks(msg)
                if let last = out.last, last["role"] as? String == "user" {
                    // 防御式合并（正常流里 user 不会连续出现）。
                    var content = out[out.count - 1]["content"] as? [[String: Any]] ?? []
                    content.append(contentsOf: blocks)
                    out[out.count - 1]["content"] = content
                } else {
                    out.append(["role": "user", "content": blocks])
                }

            case .assistant:
                var blocks: [[String: Any]] = []
                if let text = msg.content, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for tc in msg.toolCalls ?? [] {
                    blocks.append([
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.function.name,
                        "input": encodeToolInput(tc.function.arguments),
                    ])
                }
                out.append(["role": "assistant", "content": blocks])

            case .tool:
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": msg.toolCallId ?? "toolu_unknown",
                ]
                // 截图工具的结果是 data-URI 图片：tool_result 的 content 支持
                // 图片块，模型看得到截图（与 OpenAI 路径的 image_url 等价）。
                if let content = msg.content, content.hasPrefix("data:image/"),
                   let image = encodeImageBlock(content) {
                    block["content"] = [
                        ["type": "text", "text": "Screenshot of the current viewport"],
                        image,
                    ]
                } else {
                    block["content"] = msg.content ?? ""
                }
                if let last = out.last, last["role"] as? String == "user",
                   (out.last?["content"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "tool_result" }) == true {
                    appendBlock(to: out.count - 1, block)
                } else {
                    out.append(["role": "user", "content": [block]])
                }

            case .system:
                break // handled top-level
            }
        }
        return out
    }

    nonisolated private static func userTextAndImageBlocks(_ msg: AgentMessage) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if let text = msg.content, !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        for uri in msg.imageDataURIs ?? [] {
            if let image = encodeImageBlock(uri) {
                blocks.append(image)
            }
        }
        if blocks.isEmpty {
            blocks.append(["type": "text", "text": ""])
        }
        return blocks
    }

    /// `data:image/jpeg;base64,…` → Anthropic image source block.
    nonisolated private static func encodeImageBlock(_ dataURI: String) -> [String: Any]? {
        guard dataURI.hasPrefix("data:"), let comma = dataURI.firstIndex(of: ",") else { return nil }
        let header = String(dataURI[dataURI.index(dataURI.startIndex, offsetBy: 5)..<comma])
        let payload = String(dataURI[dataURI.index(after: comma)...])
        let mime = header.split(separator: ";").first.map(String.init) ?? "image/jpeg"
        return [
            "type": "image",
            "source": ["type": "base64", "media_type": mime, "data": payload],
        ]
    }

    /// Model tool-call arguments arrive as a JSON string; Anthropic wants the
    /// object. Unparseable/empty → `{}`（让模型看到空输入的反馈而不是整轮失败）。
    nonisolated private static func encodeToolInput(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    nonisolated static func encodeTool(_ t: AgentToolDef) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(t.function.parameters),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["name": t.function.name, "description": t.function.description,
                    "input_schema": ["type": "object", "properties": [:]]]
        }
        return [
            "name": t.function.name,
            "description": t.function.description,
            "input_schema": schema,
        ]
    }

    /// Drives a streaming Messages request. Assumes `request` already has
    /// method/body/headers set. Yields the same events as `OpenAICompatSSE`.
    static func stream(for request: URLRequest) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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

                    /// tool_use 块按 index 聚合：id/name 在 content_block_start，
                    /// 参数 JSON 在后续 input_json_delta 里分片到达。
                    var toolBlocks: [Int: (id: String, name: String, json: String)] = [:]
                    var inputTokens = 0
                    var outputTokens = 0
                    var sawModel = false

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue } // event: 行可忽略，type 在 data 里
                        let data = String(line.dropFirst(6))
                        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                              let type = json["type"] as? String else { continue }

                        switch type {
                        case "message_start":
                            if let message = json["message"] as? [String: Any] {
                                if !sawModel, let model = message["model"] as? String, !model.isEmpty {
                                    sawModel = true
                                    continuation.yield(.model(model))
                                }
                                if let usage = message["usage"] as? [String: Any] {
                                    inputTokens = usage["input_tokens"] as? Int ?? 0
                                }
                            }

                        case "content_block_start":
                            if let block = json["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use",
                               let index = json["index"] as? Int {
                                toolBlocks[index] = (
                                    block["id"] as? String ?? "",
                                    block["name"] as? String ?? "",
                                    ""
                                )
                            }

                        case "content_block_delta":
                            guard let delta = json["delta"] as? [String: Any],
                                  let deltaType = delta["type"] as? String else { continue }
                            switch deltaType {
                            case "text_delta":
                                if let text = delta["text"] as? String { continuation.yield(.text(text)) }
                            case "thinking_delta":
                                if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                                    continuation.yield(.reasoning(thinking))
                                }
                            case "input_json_delta":
                                if let index = json["index"] as? Int, let p = toolBlocks[index] {
                                    toolBlocks[index] = (p.id, p.name, p.json + (delta["partial_json"] as? String ?? ""))
                                }
                            default:
                                break
                            }

                        case "content_block_stop":
                            if let index = json["index"] as? Int, let p = toolBlocks[index] {
                                toolBlocks[index] = nil
                                // 参数分片可能一个都没来（空输入）——补 `{}`，id
                                // 缺失时合成（与 OpenAI 路径同一约定：agent loop
                                // 按 id 关联结果）。
                                let id = p.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(8))" : p.id
                                let args = p.json.isEmpty ? "{}" : p.json
                                continuation.yield(.toolCall(AgentToolCall(
                                    id: id,
                                    type: "function",
                                    function: AgentToolFunction(name: p.name, arguments: args)
                                )))
                            }

                        case "message_delta":
                            if let usage = json["usage"] as? [String: Any] {
                                outputTokens = usage["output_tokens"] as? Int ?? 0
                            }

                        case "error":
                            // Anthropic 也把错误塞流里（HTTP 可能仍是 200）——与
                            // OpenAI 路径同款处理，否则整轮无内容。
                            let message = (json["error"] as? [String: Any])?["message"] as? String
                                ?? "\(json["error"] ?? json)"
                            continuation.finish(throwing: AgentServiceError.httpStatus(http.statusCode, message))
                            return

                        case "message_stop":
                            if inputTokens > 0 || outputTokens > 0 {
                                continuation.yield(.usage(promptTokens: inputTokens, completionTokens: outputTokens))
                            }
                            continuation.finish()
                            return

                        default:
                            break // ping / content_block_start(text) 等无动作
                        }
                    }

                    // 服务端没发 message_stop 就断了：已聚合的用量照报，正常收尾。
                    if inputTokens > 0 || outputTokens > 0 {
                        continuation.yield(.usage(promptTokens: inputTokens, completionTokens: outputTokens))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AgentServiceError.network(error))
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

/// Cloud model provider speaking the Anthropic Messages streaming protocol
/// (api.anthropic.com and any gateway exposing the same dialect).
struct CloudAnthropicProvider: ModelProvider {
    func stream(
        messages: [AgentMessage],
        tools: [AgentToolDef],
        prefs: AgentPreferenceStore
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let apiKey = prefs.loadAPIKey() else {
                    continuation.finish(throwing: AgentServiceError.noAPIKey)
                    return
                }

                // 端点宽容补全：给了 /v1 就补 /messages，裸域就补 /v1/messages
                //（与 OpenAI 路径补 /chat/completions 同一 DX）。
                var urlStr = prefs.endpoint
                if !urlStr.hasSuffix("/messages") {
                    urlStr += urlStr.hasSuffix("/v1") ? "/messages" : "/v1/messages"
                }
                guard let url = URL(string: urlStr) else {
                    continuation.finish(throwing: AgentServiceError.network(NSError(domain: "AI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])))
                    return
                }

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 300
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.setValue("chatcmpl-\(String(UUID().uuidString.prefix(8)))", forHTTPHeaderField: "X-Request-Id")

                // 档案自定义请求头（网关租户键等）。核心三头由上面掌管。
                for (name, value) in prefs.activeHeaders {
                    let header = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !header.isEmpty,
                          !header.lowercased().hasPrefix("authorization"),
                          !header.lowercased().hasPrefix("content-type"),
                          !header.lowercased().hasPrefix("x-api-key"),
                          !header.lowercased().hasPrefix("anthropic-version") else { continue }
                    req.setValue(value, forHTTPHeaderField: header)
                }

                req.httpBody = AnthropicSSE.buildBody(
                    messages: messages,
                    tools: tools,
                    model: prefs.model,
                    maxTokens: prefs.maxTokens,
                    temperature: prefs.temperature,
                    reasoningEffort: prefs.reasoningEffort
                )

                #if DEBUG
                CloudOpenAIProvider.logRequest(url: url, model: prefs.model, messages: messages, tools: tools, body: req.httpBody)
                #endif

                let sse = AnthropicSSE.stream(for: req)
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
