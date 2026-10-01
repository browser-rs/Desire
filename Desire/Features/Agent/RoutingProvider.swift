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
/// Selection rules live in `RoutingDecision` (pure, unit-tested). This type
/// gathers the availability signals and maps the target to a concrete provider.
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
        let input = RoutingDecision.Input(
            hasToolTraffic: messages.contains { $0.role == .tool || !($0.toolCalls ?? []).isEmpty },
            toolsOffered: !tools.isEmpty,
            lockedToCloud: prefs.routingLockedToCloud,
            lastUserPrompt: messages.last(where: { $0.role == .user })?.content,
            contextChars: messages.reduce(0) { $0 + ($1.content?.count ?? 0) },
            foundationAvailable: foundationAvailable,
            ollamaConfigured: ollamaConfigured,
            hasCloudKey: prefs.hasAPIKey,
            costAware: prefs.costAwareRouting
        )
        // 锁语义 = "留在有工具能力的提供方"（原实现规则 1 命中即锁，
        // 即便回落到 Ollama 也锁）——不是"结果为云才锁"。
        if input.lockedToCloud || (input.toolsOffered && input.hasToolTraffic) {
            prefs.routingLockedToCloud = true
        }
        let target = RoutingDecision.decide(input)
        return map(target)
    }

    private func map(_ target: RoutingDecision.Target) -> ModelProviderKind {
        switch target {
        case .cloud: return .cloud
        case .foundationModels: return .foundationModels
        case .ollama: return .ollama
        }
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
        case .cloud:
            // 线协议跟当前档案走（Anthropic Messages / OpenAI 兼容）。
            return prefs.activeProfile?.format == .anthropic
                ? CloudAnthropicProvider()
                : CloudOpenAIProvider()
        case .foundationModels: return FoundationModelsProvider()
        case .ollama:           return OllamaProvider()
        case .routing:          return CloudOpenAIProvider() // defensive; routing never routes to itself
        }
    }
}
