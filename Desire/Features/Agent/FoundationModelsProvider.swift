import Foundation
import FoundationModels

/// On-device model provider backed by Apple's Foundation Models framework
/// (the Apple Intelligence language model, macOS 26+).
///
/// This is the privacy-preserving option: inference runs entirely on the
/// device, no API key, no network egress.
///
/// **Tool calling via a text protocol, not FM's native `Tool` API.** The
/// framework's `Tool` protocol runs the whole tool loop *inside* the
/// framework, which would bypass Desire's approval gating (`ToolRisk` /
/// `AgentApproval`) and our transcript bookkeeping. Instead this provider
/// describes the browser tools in the instructions and asks the model to
/// emit one machine-readable block per action:
///
///     ⟦TOOL⟧{"name":"click","arguments":{"selector":"#ok"}}⟦/TOOL⟧
///
/// The block is parsed into a `.toolCall` event and the SHARED agent loop
/// (`AgentSessionStore.processLoop`) executes it exactly like a cloud model's
/// tool call — one loop, one approval path, one transcript format.
///
/// **Adaptation strategy.** Our `ModelProvider` contract is stateless —
/// each `stream()` call receives the full `AgentMessage[]` history. But
/// `LanguageModelSession` is *stateful* (it maintains its own transcript).
/// To bridge the two, we create a **fresh session per call** and flatten
/// the history — including prior tool calls and their results — into the
/// session's `instructions`, with the final user prompt as the response
/// target. This forgoes the session's cross-call transcript caching, which
/// is acceptable for the stateless contract.
struct FoundationModelsProvider: ModelProvider {
    func stream(
        messages: [AgentMessage],
        tools: [AgentToolDef],
        prefs: AgentPreferenceStore
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // 1. Availability gate. The framework throws if you construct
                //    a session while Apple Intelligence is off / ineligible.
                switch SystemLanguageModel.default.availability {
                case .available:
                    break
                case .unavailable(let reason):
                    continuation.finish(throwing: AgentServiceError.modelUnavailable(
                        Self.describeUnavailable(reason)
                    ))
                    return
                @unknown default:
                    continuation.finish(throwing: AgentServiceError.modelUnavailable(
                        "Apple Intelligence is not available on this device."
                    ))
                    return
                }

                let hasTools = !tools.isEmpty
                let instructions = Self.buildInstructions(
                    from: messages, base: prefs.systemPrompt, tools: hasTools ? tools : nil
                )
                let finalPrompt = Self.buildFinalPrompt(from: messages)

                let session = LanguageModelSession(instructions: instructions)

                // 2. Stream the response. In tool mode the text passes through
                //    a holdback window so a partial tool delimiter never leaks
                //    into the visible chat; at stream end the block is parsed
                //    into a `.toolCall` for the shared agent loop.
                do {
                    let responseStream = session.streamResponse(to: finalPrompt)
                    var buffer = ""
                    let holdback = 24

                    for try await snapshot in responseStream {
                        let chunk = snapshot.content
                        guard !chunk.isEmpty else { continue }
                        if hasTools {
                            buffer += chunk
                            if buffer.count > holdback {
                                let split = buffer.index(buffer.endIndex, offsetBy: -holdback)
                                continuation.yield(.text(String(buffer[..<split])))
                                buffer.removeSubrange(buffer.startIndex..<split)
                            }
                        } else {
                            continuation.yield(.text(chunk))
                        }
                    }

                    if hasTools {
                        if let block = Self.extractToolBlock(buffer) {
                            let visible = block.visiblePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !visible.isEmpty { continuation.yield(.text(visible)) }
                            if let call = Self.parseToolCall(block.json) {
                                continuation.yield(.toolCall(call))
                            } else {
                                continuation.yield(.text(
                                    "\n" + String(localized: "On-device model emitted an unparseable action — ignored.")
                                ))
                            }
                        } else if !buffer.isEmpty {
                            continuation.yield(.text(buffer))
                        }
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: AgentServiceError.network(
                        NSError(domain: "FoundationModels", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: Self.describeGenerationError(error)])
                    ))
                } catch {
                    continuation.finish(throwing: AgentServiceError.network(error))
                }
            }
        }
    }

    // MARK: - Text tool protocol

    private static let toolOpen = "⟦TOOL⟧"
    private static let toolClose = "⟦/TOOL⟧"

    /// Splits a finished response into the visible text before the tool
    /// block and the JSON inside it. An unterminated block (model ran out
    /// of tokens) still parses — the remainder after the opener is the JSON.
    private static func extractToolBlock(_ text: String) -> (visiblePrefix: String, json: String)? {
        guard let openRange = text.range(of: toolOpen) else { return nil }
        let afterOpen = text[openRange.upperBound...]
        let json: String
        if let closeRange = afterOpen.range(of: toolClose) {
            json = String(afterOpen[..<closeRange.lowerBound])
        } else {
            json = String(afterOpen)
        }
        return (String(text[..<openRange.lowerBound]), json)
    }

    /// Accepts `{"name": ..., "arguments": {...}}` with tolerant key aliases
    /// ("tool"/"args"), since the on-device model's key discipline is loose.
    private static func parseToolCall(_ json: String) -> AgentToolCall? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = (obj["name"] as? String) ?? (obj["tool"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let args = (obj["arguments"] as? [String: Any]) ?? (obj["args"] as? [String: Any]) ?? [:]
        let argsString = (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return AgentToolCall(
            id: "fm_\(UUID().uuidString.prefix(8))",
            type: "function",
            function: AgentToolFunction(name: name, arguments: argsString)
        )
    }

    // MARK: - History flattening

    /// Builds session instructions: the user's system prompt, the tool
    /// protocol (when tools are offered), and the prior turns — INCLUDING
    /// tool calls and their results, so multi-step flows keep their context.
    private static func buildInstructions(
        from messages: [AgentMessage], base: String, tools: [AgentToolDef]?
    ) -> String {
        var lines: [String] = []
        if !base.isEmpty { lines.append(base) }

        if let tools, !tools.isEmpty {
            let catalog = tools
                .map { "- \($0.function.name): \($0.function.description)" }
                .joined(separator: "\n")
            lines.append("""
            You can control this browser. Available actions:
            \(catalog)

            To perform an action, respond with EXACTLY one machine block and nothing else:
            \(toolOpen){"name":"actionName","arguments":{"param":"value"}}\(toolClose)

            The action's result arrives as a "Result of …" note in the next turn; then continue.
            If no action is needed, answer the user in plain text without the block.
            """)
        }

        let history = messages.dropLast()
        for msg in history {
            let content = msg.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch msg.role {
            case .system:
                if !content.isEmpty { lines.append(content) }
            case .user:
                if !content.isEmpty { lines.append("User: \(content)") }
            case .assistant:
                if let tcs = msg.toolCalls, !tcs.isEmpty {
                    let requested = tcs
                        .map { "\($0.function.name)(\($0.function.arguments.prefix(300)))" }
                        .joined(separator: "; ")
                    let said = content.isEmpty ? "" : " It said: \(content.prefix(300))"
                    lines.append("Assistant requested actions: \(requested).\(said)")
                } else if !content.isEmpty {
                    lines.append("Assistant: \(content)")
                }
            case .tool:
                let name = msg.toolName ?? "action"
                let result = String((msg.content ?? "").prefix(1500))
                lines.append("Result of \(name): \(result)")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Extracts the final user prompt from the conversation. Falls back to
    /// an empty string if the last message isn't a user turn (the model will
    /// still respond, using the instructions as context).
    private static func buildFinalPrompt(from messages: [AgentMessage]) -> String {
        if let last = messages.last, last.role == .user {
            return last.content ?? ""
        }
        // No trailing user message — ask the model to continue the conversation.
        return "Continue."
    }

    // MARK: - Error descriptions

    private static func describeUnavailable(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        // Map the known reasons to actionable copy so the user knows how to
        // recover. The enum is @frozen so this switch is exhaustive.
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled. Turn it on in System Settings > Apple Intelligence."
        case .modelNotReady:
            return "The on-device model is still preparing. Try again in a moment."
        @unknown default:
            return "Apple Intelligence is unavailable on this device."
        }
    }

    private static func describeGenerationError(_ error: LanguageModelSession.GenerationError) -> String {
        // GenerationError is an enum; describe it generically. Specific
        // cases (guardrailViolation, exceededContextWindowSize, etc.) could
        // be mapped to friendlier copy later.
        "Generation failed: \(error)"
    }
}
