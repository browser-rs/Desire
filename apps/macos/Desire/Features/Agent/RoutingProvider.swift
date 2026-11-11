import Foundation
import FoundationModels
import os

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
        // 本地优先档失败回退（v0.8.53 批 3）：本地流抛错且**什么都没流出来**
        // 时回退云（与备用档案 failover 同口径——已流出正文不重试，避免重复）。
        // 有云 Key 才回退；工具链锁定态不在此路径（decide 已保证）。
        if target != .cloud, prefs.hasAPIKey {
            let local = concrete(for: target)
            let cloud = concrete(for: .cloud)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    var emitted = false
                    do {
                        for try await event in local.stream(messages: messages,
                                                            tools: tools, prefs: prefs) {
                            emitted = true
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        guard !emitted else {
                            continuation.finish(throwing: error)
                            return
                        }
                        Log.agent.info("local routing failed before any output — falling back to cloud")
                        onDecision(.cloud)
                        do {
                            for try await event in cloud.stream(messages: messages,
                                                                tools: tools, prefs: prefs) {
                                continuation.yield(event)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
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
            costAware: prefs.costAwareRouting,
            aggressive: prefs.aggressiveLocalRouting
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
