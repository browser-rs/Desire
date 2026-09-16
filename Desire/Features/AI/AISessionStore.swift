import Combine
import WebKit

enum AIQuickAction: CaseIterable {
    case summarize
    case askAboutPage
    case translate
    case summarizeComments
    case summarizeChat

    var title: String {
        switch self {
        case .summarize: String(localized: "Summarize")
        case .askAboutPage: String(localized: "Ask about Page")
        case .translate: String(localized: "Translate")
        case .summarizeComments: String(localized: "Summarize Comments")
        case .summarizeChat: String(localized: "Summarize Chat")
        }
    }

    var icon: String {
        switch self {
        case .summarize: "text.alignleft"
        case .askAboutPage: "text.bubble"
        case .translate: "translate"
        case .summarizeComments: "bubble.left.and.text.bubble.right"
        case .summarizeChat: "message.badge.filled.fill"
        }
    }

    var prompt: String {
        switch self {
        case .summarize: String(localized: "Summarize the current page in detail")
        case .askAboutPage: String(localized: "I'm looking at this page and want to ask:")
        case .translate: String(localized: "Translate this page to Chinese")
        case .summarizeComments:
            String(localized: "Use the getComments tool to read this page's comments, then summarize the main viewpoints, points of agreement and disagreement, and the overall sentiment.")
        case .summarizeChat:
            String(localized: "Use the getConversation tool to read this chat, then summarize what has been discussed and draft a suitable reply for me to send.")
        }
    }
}

@MainActor
class AISessionStore: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var isProcessing = false
    @Published var currentAction: String?
    @Published var awaitingQuestion = false
    @Published var streamingVersion = 0
    @Published var conversationId: UUID?
    @Published var conversationTitle: String?
    /// When non-nil, the agent loop is paused waiting for the user to approve
    /// (or deny) a tool call. The UI renders `ToolApprovalBar` from this.
    /// See `docs/ARCHITECTURE.md` (AgentRuntime v2, roadmap L3 stage 2).
    @Published var pendingApproval: PendingToolApproval?

    /// Human-readable label of the provider that handled the most recent
    /// stream call (e.g. "Cloud", "On-device", "Ollama"). Set by
    /// `RoutingProvider`'s onDecision callback when `providerKind == .routing`;
    /// `nil` otherwise. The AI panel shows it as a "via ..." badge.
    @Published var lastProviderUsed: String?

    /// Human-readable description of the page the agent will act on
    /// ("Title — host"), shown in the AI panel header. Always describes the
    /// REAL tool target (`activeWebView`), never a stale pointer.
    @Published var contextLabel: String?

    /// Token-delivery progress during streaming. Reset on `sendMessage`.
    @Published var streamingTokenCount = 0
    @Published var streamingTokensPerSecond: Double = 0

    /// AI preferences (model, endpoint, API key, provider kind, ...). Owned
    /// by `AIState` and injected here so the Settings window and the agent
    /// loop share the exact same instance — edits in Settings reach the live
    /// agent, and `routingLockedToCloud` is visible everywhere.
    let preference: AIPreferenceStore
    /// Conversation history store. Strongly held by `AIState`; injected here
    /// at construction so save/load paths work without post-init wiring.
    let conversationStore: ConversationStore
    private let toolProvider = BrowserToolProvider()
    /// Strong ref to the configured surface. `BrowserToolProvider.surface`
    /// is weak, and a per-window `WindowToolSurface` has no other owner —
    /// without this it deallocates as soon as `configure(with:)` returns
    /// and every tool call fails with "Tool surface not configured".
    private var toolSurface: (any BrowserToolSurface)?
    private weak var webView: WKWebView?
    private var isCancelled = false
    private var loopTask: Task<Void, Never>?
    /// True after `clear()` until a conversation is loaded or a message is
    /// sent — gates `resumeLatestConversation` so a deliberate new chat
    /// stays blank when the panel is reopened.
    private var isNewChatIntentional = false

    init(preference: AIPreferenceStore, conversationStore: ConversationStore) {
        self.preference = preference
        self.conversationStore = conversationStore
    }

    /// Soft cap on agent loop iterations to prevent runaway execution.
    /// Replaces the old hardcoded `0..<20` limit. Configurable later.
    private let maxIterations = 50

    /// Builds the provider the agent loop will call for this iteration.
    /// Returns the provider and the initial "via ..." label to show in the UI
    /// (nil for non-routing kinds). The caller sets `lastProviderUsed`
    /// explicitly — this is a factory method, not a getter with side effects
    /// (the old `activeProvider` computed property mutated `lastProviderUsed`
    /// on read, which broke the getter-purity contract and could trigger
    /// spurious SwiftUI invalidations).
    private func makeActiveProvider() -> (provider: any ModelProvider, viaLabel: String?) {
        if preference.providerKind == .routing {
            let provider = RoutingProvider(prefs: preference) { [weak self] kind in
                self?.lastProviderUsed = kind.viaLabel
            }
            return (provider, "Auto")
        } else {
            return (preference.provider, nil)
        }
    }

    func setWebView(_ wv: WKWebView?) {
        // `makeWebView` (a View-body helper) calls this on EVERY render of
        // the tab content. Publishing must not happen during view updates —
        // and @Published fires objectWillChange even for identical values —
        // so no-op when the webview didn't actually change, which is the
        // overwhelming majority of calls. Without this, having the AI panel
        // open turned every progress tick / hover into an AIPanel
        // re-render storm ("Publishing changes from within view updates").
        guard webView !== wv else { return }
        webView = wv
        refreshContextLabel()
    }

    /// The webview the agent operates on, resolved AT CALL TIME: the active
    /// window's selected tab (via the tool surface), falling back to the
    /// last-bound webview. The old code used the stored `webView` directly —
    /// with multiple windows it was whichever window rendered last, so the
    /// agent could read and click the WRONG window's page.
    private var activeWebView: WKWebView? {
        toolProvider.surface?.tabManager?.selectedTab?.browser.webView ?? webView
    }

    private func refreshContextLabel() {
        let newLabel: String?
        if let wv = activeWebView {
            let host = wv.url?.host ?? ""
            let title = (wv.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch (title.isEmpty, host.isEmpty) {
            case (true, true): newLabel = nil
            case (true, false): newLabel = host
            case (false, true): newLabel = title
            case (false, false): newLabel = "\(title) — \(host)"
            }
        } else {
            newLabel = nil
        }
        // Assign only on an actual change — a bare assignment publishes
        // objectWillChange even when the value is identical.
        if contextLabel != newLabel {
            contextLabel = newLabel
        }
    }

    /// Attaches the browser tool surface (the app-state slice tools operate
    /// over). Replaces the former 13-parameter `configureStores`. The tab
    /// manager is per-window, so the caller must also attach it to the
    /// surface (via `AppState.attach(tabManager:)`).
    func configure(with surface: BrowserToolSurface) {
        toolSurface = surface
        toolProvider.attach(surface: surface)
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(AIMessage(role: .user, content: trimmed))
        if conversationId == nil {
            conversationTitle = String(trimmed.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        saveCurrentConversation()
        isProcessing = true
        isCancelled = false
        refreshContextLabel()
        streamingTokenCount = 0
        streamingTokensPerSecond = 0
        loopTask = Task { await processLoop() }
    }

    func performQuickAction(_ action: AIQuickAction) {
        switch action {
        case .summarize, .translate, .summarizeComments, .summarizeChat:
            // These prompts instruct the agent to pull content via the
            // specialized tools (getComments / getConversation).
            sendMessage(action.prompt)
        case .askAboutPage:
            awaitingQuestion = true
            Task {
                let text = await fetchPageText()
                let context = "[Current Page Content]\n\(text)\n\n---\n\(action.prompt)"
                messages.append(AIMessage(role: .user, content: context))
            }
        }
    }

    func sendFollowUp(_ text: String) {
        awaitingQuestion = false
        sendMessage(text)
    }

    func addContext(html: String, selector: String) {
        let context = "<\(selector)>: \(html.prefix(1000))"
        messages.append(AIMessage(role: .user, content: "[Selected element]\n\(context)"))
    }

    /// Adds the user's text selection as context; the next typed message can
    /// reference it ("翻译一下" / "解释第二段" …).
    func addSelectedTextContext(_ text: String) {
        messages.append(AIMessage(role: .user, content: "[Selected text]\n\(text)"))
    }

    func cancel() {
        isCancelled = true
        isProcessing = false
        currentAction = nil
        awaitingQuestion = false
        // Cancel the streaming Task so the for-try-await loop stops
        // immediately instead of waiting for the next event/timeout.
        loopTask?.cancel()
        loopTask = nil
        // If waiting on an approval, resume the suspended continuation with
        // a deny so the loop wakes up and sees `isCancelled`.
        if let approval = pendingApproval {
            approval.resume(with: .denied)
            pendingApproval = nil
        }
    }

    func clear() {
        messages.removeAll()
        conversationId = nil
        conversationTitle = nil
        isProcessing = false
        currentAction = nil
        isCancelled = false
        awaitingQuestion = false
        // The user deliberately started a new chat — reopening the panel
        // should NOT resurrect the previous conversation.
        isNewChatIntentional = true
        // Reset the router's session-sticky lock so a new conversation
        // starts fresh (a prior tool chain shouldn't pin the new one to cloud).
        preference.routingLockedToCloud = false
        lastProviderUsed = nil
    }

    /// Called when a chat surface (sidebar or floating panel) becomes
    /// visible: if the session is blank and the user didn't just start a
    /// new chat, load the most recent conversation instead of showing an
    /// empty panel. `conversations` is kept sorted by `updatedAt` desc.
    func resumeLatestConversation() {
        guard messages.isEmpty, !isProcessing, !isNewChatIntentional else { return }
        guard let latest = conversationStore.conversations.first else { return }
        loadConversation(latest.id)
    }

    func loadConversation(_ id: UUID) {
        guard let conv = conversationStore.conversation(for: id) else { return }
        messages = conv.messages
        conversationId = conv.id
        conversationTitle = conv.title
        awaitingQuestion = false
        currentAction = nil
        isNewChatIntentional = false
        streamingVersion += 1
    }

    private func saveCurrentConversation() {
        let id = conversationId ?? UUID()
        conversationId = id
        let title: String
        if let t = conversationTitle, !t.isEmpty {
            title = t
        } else if let firstUserMsg = messages.first(where: { $0.role == .user })?.content {
            title = String(firstUserMsg.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        } else {
            title = "New Conversation"
        }
        conversationTitle = title
        let conv = Conversation(id: id, title: title, createdAt: Date(), updatedAt: Date(), messages: messages)
        conversationStore.save(conv)
    }

    private func fetchPageText() async -> String {
        guard let wv = activeWebView else { return "" }
        return await withCheckedContinuation { continuation in
            wv.evaluateJavaScript("document.body.innerText.substring(0, 20000)") { result, _ in
                continuation.resume(returning: (result as? String) ?? "")
            }
        }
    }

    private func processLoop() async {
        defer {
            isProcessing = false
            currentAction = nil
        }

        // AgentRuntime v2: budget-based loop replaces the old hardcoded
        // `0..<20` iteration cap. The soft limit (`maxIterations`) prevents
        // runaway execution while allowing genuinely long multi-step tasks.
        var iterations = 0
        var hitIterationCap = false

        while !isCancelled && iterations < maxIterations {
            iterations += 1

            // Tool definitions must be sent on EVERY call in a tool-use
            // conversation: the second call sends back tool results, and
            // the model still needs to know the tool schemas to decide
            // what to do next (or to make another tool call).
            //
            // Routed through `activeProvider` (a `ModelProvider`) instead of
            // `AIService` directly, so Foundation Models / Ollama / a routing
            // provider can be swapped in without touching the agent loop.
            // When `providerKind == .routing`, each call may target a
            // different concrete provider and report it via lastProviderUsed.
            let active = makeActiveProvider()
            lastProviderUsed = active.viaLabel
            let stream = active.provider.stream(
                messages: messages,
                tools: BrowserToolProvider.toolDefs + MCPStore.shared.toolDefs,
                prefs: preference
            )

            var assistantMsg: AIMessage?
            var hasContent = false
            var lastTokenTime = Date()

            do {
                for try await event in stream {
                    if isCancelled { return }
                    switch event {
                    case .text(let delta):
                        if assistantMsg == nil {
                            assistantMsg = AIMessage(role: .assistant, content: "")
                            messages.append(assistantMsg!)
                        }
                        assistantMsg!.content = (assistantMsg!.content ?? "") + delta
                        if let idx = messages.lastIndex(where: { $0.id == assistantMsg!.id }) {
                            messages[idx] = assistantMsg!
                            streamingVersion += 1
                        }
                        hasContent = true
                        streamingTokenCount += 1
                        let now = Date()
                        let interval = now.timeIntervalSince(lastTokenTime)
                        if interval > 0.001 {
                            streamingTokensPerSecond = 1.0 / interval
                        }
                        lastTokenTime = now
                    case .toolCall(let call):
                        if assistantMsg == nil {
                            assistantMsg = AIMessage(role: .assistant, content: "")
                            messages.append(assistantMsg!)
                        }
                        assistantMsg!.toolCalls = (assistantMsg!.toolCalls ?? []) + [call]
                        if let idx = messages.lastIndex(where: { $0.id == assistantMsg!.id }) {
                            messages[idx] = assistantMsg!
                            streamingVersion += 1
                        }
                        hasContent = true
                    }
                }
            } catch {
                let errorText = "Error: \(error.localizedDescription)"
                if let idx = assistantMsg.flatMap({ m in messages.firstIndex(where: { $0.id == m.id }) }) {
                    messages[idx].content = errorText
                    messages[idx].toolCalls = nil
                } else {
                    messages.append(AIMessage(role: .assistant, content: errorText))
                }
                streamingVersion += 1
                return
            }

            guard hasContent, let msg = assistantMsg else { return }

            if assistantMsg?.content?.isEmpty ?? true {
                if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                    messages[idx] = msg
                }
            }

            guard let tcs = msg.toolCalls, !tcs.isEmpty else { return }

            // Execute tool calls with risk-gated approval. Each call may
            // pause the loop (via a continuation) until the user decides.
            for tc in tcs {
                if isCancelled { return }
                let risk = ToolRisk.classify(tc.function.name)

                let decision = await gate(toolCall: tc, risk: risk)
                switch decision {
                case .denied:
                    // Tell the model the user declined, so it can adapt.
                    messages.append(AIMessage(
                        role: .tool,
                        content: "[User denied this action (\(tc.function.name)).]",
                        toolCallId: tc.id,
                        toolName: tc.function.name
                    ))
                    continue
                case .allowedOnce, .allowedAlways:
                    break
                }

                currentAction = tc.function.name
                let result = await toolProvider.execute(tc, in: activeWebView ?? WKWebView())
                messages.append(AIMessage(
                    role: .tool,
                    content: result,
                    toolCallId: tc.id,
                    toolName: tc.function.name
                ))
            }
            currentAction = nil
            // Tools may have navigated the page — the context label must
            // describe the post-action state.
            refreshContextLabel()
            saveCurrentConversation()

            if iterations >= maxIterations {
                hitIterationCap = true
            }
        }

        if hitIterationCap && !isCancelled {
            messages.append(AIMessage(
                role: .assistant,
                content: "⚠️ Reached the maximum number of steps (\(maxIterations)). Stopping to avoid runaway execution."
            ))
            streamingVersion += 1
            saveCurrentConversation()
        }
    }

    // MARK: - Tool approval gating

    /// Decides whether a tool call may run. Returns the outcome — the loop
    /// then either executes the tool, appends a denial, or (if cancelled)
    /// returns. `.readonly` tools and whitelisted tools bypass the prompt.
    private func gate(toolCall: AIToolCall, risk: ToolRisk) async -> ApprovalOutcome {
        if isCancelled { return .denied }

        // Safe tools always run.
        if risk == .readonly { return .allowedOnce }

        // Whitelisted side-effect tools run without prompting. Dangerous
        // tools are exempt from the whitelist and always prompt.
        if risk != .dangerous && preference.allowedTools.contains(toolCall.function.name) {
            return .allowedOnce
        }

        // Everything else pauses for the user.
        return await requestApproval(toolCall: toolCall, risk: risk)
    }

    /// Suspends the loop until the user resolves the pending approval.
    /// The continuation is resumed by `resolveApproval(_:)`.
    private func requestApproval(toolCall: AIToolCall, risk: ToolRisk) async -> ApprovalOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalOutcome, Never>) in
            pendingApproval = PendingToolApproval(
                toolCall: toolCall,
                risk: risk,
                argumentsSummary: summarizeArguments(toolCall),
                continuation: continuation
            )
        }
    }

    /// Called by the UI (`ToolApprovalBar`) when the user decides.
    func resolveApproval(_ decision: ApprovalDecision) {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil

        let outcome: ApprovalOutcome
        switch decision {
        case .allowOnce:
            outcome = .allowedOnce
        case .alwaysAllow:
            // Persist the whitelist entry. Dangerous tools never reach here
            // because the UI disables the "Always Allow" button for them.
            if approval.risk != .dangerous {
                var current = preference.allowedTools
                current.insert(approval.toolCall.function.name)
                preference.allowedTools = current
            }
            outcome = .allowedAlways
        case .deny:
            outcome = .denied
        }
        approval.resume(with: outcome)
    }

    /// Produces a short human-readable summary of a tool call's arguments
    /// for display in the approval bar. Falls back to the raw JSON if
    /// parsing fails.
    private func summarizeArguments(_ call: AIToolCall) -> String {
        guard let data = call.function.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !dict.isEmpty else {
            return call.function.arguments.isEmpty ? "(no arguments)" : call.function.arguments
        }
        // Show key=value pairs, truncating long values.
        return dict.map { key, value in
            let valStr = String(describing: value)
            let truncated = valStr.count > 60 ? String(valStr.prefix(60)) + "…" : valStr
            return "\(key): \(truncated)"
        }.joined(separator: ", ")
    }
}

    // MARK: - Approval types

    /// A pending tool-call approval. Published by `AISessionStore` so the UI
/// can render a prompt; the embedded continuation resumes the loop when
/// the user decides (or when the conversation is cancelled).
///
/// `@MainActor` because it's only ever constructed, observed, and resumed
/// on the main actor (the store is `@MainActor`).
@MainActor
final class PendingToolApproval: Identifiable {
    let id = UUID()
    let toolCall: AIToolCall
    let risk: ToolRisk
    let argumentsSummary: String
    private var continuation: CheckedContinuation<ApprovalOutcome, Never>?

    init(toolCall: AIToolCall, risk: ToolRisk, argumentsSummary: String,
         continuation: CheckedContinuation<ApprovalOutcome, Never>) {
        self.toolCall = toolCall
        self.risk = risk
        self.argumentsSummary = argumentsSummary
        self.continuation = continuation
    }

    /// Resumes the suspended loop with the given outcome. Idempotent —
    /// calling twice is a no-op (guard against double-resume if cancel()
    /// and resolveApproval() race).
    func resume(with outcome: ApprovalOutcome) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: outcome)
    }
}
