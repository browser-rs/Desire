import Foundation
import FoundationModels

/// A `ModelProvider` that picks among the concrete providers per call based
/// on lightweight rules, delivering the "full model strategy" automatically:
/// summaries/translations run on-device (privacy, offline), complex actions
/// and tool chains run in the cloud.
///
/// The decision is **session-sticky for tool chains**: once a conversation
/// turns to tool use (a `.tool` message appears, or the model emitted tool
/// calls), every subsequent call in that conversation routes to a
/// tool-capable provider. This is mandatory because `FoundationModelsProvider`
/// is text-only — it cannot ingest tool-result messages, so routing a
/// mid-chain call to it would corrupt the conversation.
///
/// The sticky flag lives on `AgentPreferenceStore.routingLockedToCloud`
/// (non-persistent; resets each launch) because `RoutingProvider` itself is
/// a value type reconstructed on every `stream()` call.
///
/// Selection rules (first match wins):
/// 1. Tool chain in progress (`!tools.isEmpty` AND history contains tool
///    messages / tool calls) → tool-capable: cloud first, Ollama fallback.
/// 2. Local-eligible prompt (summary/translate/tldr keywords, no tools) →
///    Foundation Models first, then Ollama, then cloud.
/// 3. Default → cloud.
///
/// Availability gate: cloud requires an API key; Foundation Models requires
/// `SystemLanguageModel.availability == .available`; Ollama is always
/// considered available (connection errors surface from the provider itself).
struct RoutingProvider: ModelProvider {
    let prefs: AgentPreferenceStore
    /// Notified of every routing decision so the UI can show a
    /// "via Cloud / via On-device" label.
    let onDecision: (ModelProviderKind) -> Void

    func stream(
        messages: [AgentMessage],
        tools: [AgentToolDef],
        prefs: AgentPreferenceStore
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let target = decide(messages: messages, tools: tools)
        onDecision(target)
        return concrete(for: target).stream(messages: messages, tools: tools, prefs: prefs)
    }

    // MARK: - Decision

    private func decide(messages: [AgentMessage], tools: [AgentToolDef]) -> ModelProviderKind {
        // Rule 1: once we've entered a tool chain, stay tool-capable.
        // `tools` is non-empty on every call of a tool-use conversation,
        // and tool-result messages appear after the first tool executes.
        let hasToolTraffic = messages.contains { $0.role == .tool || !($0.toolCalls ?? []).isEmpty }
        if prefs.routingLockedToCloud || (!tools.isEmpty && hasToolTraffic) {
            prefs.routingLockedToCloud = true
            return toolCapableFallback()
        }

        // Rule 2: local-eligible prompt. Only when no tools are offered —
        // a summarization that *can* call tools might, and then rule 1 applies.
        if tools.isEmpty, let lastUser = messages.last(where: { $0.role == .user })?.content?.lowercased(),
           Self.looksLocalEligible(lastUser) {
            if foundationAvailable { return .foundationModels }
            if ollamaConfigured { return .ollama }
            // No local option available → cloud.
            return .cloud
        }

        // Rule 3: default.
        return .cloud
    }

    /// Picks a tool-capable provider, preferring cloud (richer models for
    /// multi-step reasoning) and falling back to Ollama (also supports tools).
    /// Foundation Models is never considered here (text-only).
    private func toolCapableFallback() -> ModelProviderKind {
        if prefs.hasAPIKey { return .cloud }
        if ollamaConfigured { return .ollama }
        // No tool-capable provider configured. Return cloud anyway so the
        // provider surfaces a clear `.noAPIKey` error to the user, rather
        // than silently degrading to a text-only model that ignores tools.
        return .cloud
    }

    // MARK: - Availability

    private var foundationAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    private var ollamaConfigured: Bool {
        // Ollama needs no credentials; we treat any non-empty host/model as
        // "configured". Real reachability is checked at request time.
        !prefs.ollamaHost.isEmpty && !prefs.ollamaModel.isEmpty
    }

    private func concrete(for kind: ModelProviderKind) -> any ModelProvider {
        switch kind {
        case .cloud:            return CloudOpenAIProvider()
        case .foundationModels: return FoundationModelsProvider()
        case .ollama:           return OllamaProvider()
        case .routing:          return CloudOpenAIProvider() // defensive; routing never routes to itself
        }
    }

    /// Heuristic: does this prompt look like a pure text task suited to a
    /// small local model (summarization/translation)? Conservative — when
    /// in doubt, returns false so the cloud default applies.
    private static func looksLocalEligible(_ prompt: String) -> Bool {
        let keywords = [
            // English
            "summarize", "summary", "tldr", "tl;dr", "recap",
            "translate", "translation",
            // Chinese
            "总结", "摘要", "概括", "翻译", "简述",
        ]
        return keywords.contains { prompt.contains($0) }
    }
}
