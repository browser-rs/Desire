import Foundation
import FoundationModels

/// On-device model provider backed by Apple's Foundation Models framework
/// (the Apple Intelligence language model, macOS 26+).
///
/// This is the privacy-preserving option: inference runs entirely on the
/// device, no API key, no network egress. Best for summarization,
/// translation, and Q&A over the current page.
///
/// **Stage-1 scope: text-only streaming.** Tool calling is NOT supported
/// here. Foundation Models uses its own `Tool` protocol with `@Generable`
/// argument types, which differs structurally from our OpenAI-style
/// JSON-schema tools (`AIToolDef`). Bridging the 48 browser tools to the
/// `Tool` protocol is part of AgentRuntime v2. For now:
/// - Pure-text tasks (summarize, translate, ask-about-page) stream normally.
/// - If tools are requested, the model responds in text and we append a
///   notice that tool actions are unavailable on this provider.
///
/// **Adaptation strategy.** Our `ModelProvider` protocol is stateless —
/// each `stream()` call receives the full `AIMessage[]` history. But
/// `LanguageModelSession` is *stateful* (it maintains its own transcript).
/// To bridge the two, we create a **fresh session per call** and flatten
/// the history into (a) the session's `instructions` (system + prior
/// assistant turns) and (b) the final user prompt. This forgoes the
/// session's cross-call transcript caching, which is acceptable for the
/// stateless contract.
struct FoundationModelsProvider: ModelProvider {
    func stream(
        messages: [AIMessage],
        tools: [AIToolDef],
        prefs: AIPreferenceStore
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // 1. Availability gate. The framework throws if you construct
                //    a session while Apple Intelligence is off / ineligible.
                switch SystemLanguageModel.default.availability {
                case .available:
                    break
                case .unavailable(let reason):
                    continuation.finish(throwing: AIServiceError.modelUnavailable(
                        Self.describeUnavailable(reason)
                    ))
                    return
                @unknown default:
                    continuation.finish(throwing: AIServiceError.modelUnavailable(
                        "Apple Intelligence is not available on this device."
                    ))
                    return
                }

                // 2. Flatten history into instructions + final prompt.
                //    Tool-role messages are dropped: they carry raw tool
                //    results whose format would confuse the local model.
                let conversation = messages.filter { $0.role != .tool }
                let instructions = Self.buildInstructions(from: conversation, base: prefs.systemPrompt)
                let finalPrompt = Self.buildFinalPrompt(from: conversation)

                let session = LanguageModelSession(instructions: instructions)

                // 3. Stream the response.
                do {
                    let responseStream = session.streamResponse(to: finalPrompt)
                    for try await snapshot in responseStream {
                        let chunk = snapshot.content
                        if !chunk.isEmpty {
                            continuation.yield(.text(chunk))
                        }
                    }
                    // 4. If tools were requested but unsupported, append a
                    //    notice so the user understands why no action ran.
                    if !tools.isEmpty {
                        continuation.yield(.text(
                            "\n\n_(The on-device model cannot perform browser actions. Switch to a cloud or Ollama provider in Settings to use tools.)_"
                        ))
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: AIServiceError.network(
                        NSError(domain: "FoundationModels", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: Self.describeGenerationError(error)])
                    ))
                } catch {
                    continuation.finish(throwing: AIServiceError.network(error))
                }
            }
        }
    }

    // MARK: - History flattening

    /// Builds session instructions: the user's system prompt followed by
    /// earlier turns (assistant responses and prior user messages), so the
    /// model has conversational context.
    private static func buildInstructions(from messages: [AIMessage], base: String) -> String {
        // The last message is the current user prompt — it goes to
        // streamResponse(to:), not the instructions.
        let history = messages.dropLast()

        var lines: [String] = []
        if !base.isEmpty {
            lines.append(base)
        }
        for msg in history {
            let content = msg.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { continue }
            switch msg.role {
            case .system:
                lines.append(content)
            case .user:
                lines.append("User: \(content)")
            case .assistant:
                lines.append("Assistant: \(content)")
            case .tool:
                // Already filtered out, but guard for safety.
                continue
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Extracts the final user prompt from the conversation. Falls back to
    /// an empty string if the last message isn't a user turn (the model will
    /// still respond, using the instructions as context).
    private static func buildFinalPrompt(from messages: [AIMessage]) -> String {
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
        }
    }

    private static func describeGenerationError(_ error: LanguageModelSession.GenerationError) -> String {
        // GenerationError is an enum; describe it generically. Specific
        // cases (guardrailViolation, exceededContextWindowSize, etc.) could
        // be mapped to friendlier copy later.
        "Generation failed: \(error)"
    }
}
