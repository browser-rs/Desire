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

    /// FULL ACCESS mode: when on, EVERY tool — including dangerous-tier
    /// `executeJS` — runs without approval prompts. The user has explicitly
    /// delegated all tool decisions to the agent. Persisted; the panel
    /// shows a prominent indicator while active.
    @Published var fullAccess: Bool {
        didSet { UserDefaults.standard.set(fullAccess, forKey: "aiFullAccess") }
    }

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
        fullAccess = UserDefaults.standard.bool(forKey: "aiFullAccess")
    }

    /// Soft cap on agent loop iterations to prevent runaway execution.
    /// Replaces the old hardcoded `0..<20` limit. Configurable later.
    private let maxIterations = 50
    /// Message count already digested by background memory extraction —
    /// gates the next extraction until enough NEW turns accumulate.
    private var memoryProcessedCount = 0

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

    func sendMessage(_ text: String, images: [String]? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !(images ?? []).isEmpty else { return }
        messages.append(AIMessage(role: .user, content: trimmed, images: images))
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

    /// Re-runs the LAST user message: drops every message after it (the
    /// assistant reply and any tool traffic) and restarts the agent loop.
    func regenerate() {
        guard !isProcessing,
              let lastUser = messages.lastIndex(where: { $0.role == .user }),
              lastUser < messages.count - 1 else { return }
        messages.removeSubrange((lastUser + 1)...)
        isProcessing = true
        isCancelled = false
        refreshContextLabel()
        streamingTokenCount = 0
        streamingTokensPerSecond = 0
        loopTask = Task { await processLoop() }
    }

    func clear() {
        // The conversation is about to disappear — capture its L2 summary
        // first so "新对话" doesn't erase what happened.
        if preference.memoryLearning, messages.count >= 8, let cid = conversationId {
            let snapshot = messages
            Task { await MemoryExtractor.summarize(
                preference: preference,
                memory: AgentMemoryStore.shared,
                conversationId: cid,
                messages: snapshot
            ) }
        }
        memoryProcessedCount = 0
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
        memoryProcessedCount = messages.count
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
        // Persist WITHOUT image payloads — a few screenshots would balloon
        // the conversation JSON (and every launch's loadAll) to megabytes.
        // The text survives; images are session-scoped.
        let persistedMessages = messages.map { msg -> AIMessage in
            var copy = msg
            copy.imageDataURIs = nil
            return copy
        }
        let conv = Conversation(id: id, title: title, createdAt: Date(), updatedAt: Date(), messages: persistedMessages)
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

    /// Transient provider failures worth one automatic retry: rate limits,
    /// server errors, and dropped/timed-out connections.
    private static func isTransientStreamError(_ error: Error) -> Bool {
        switch error {
        case AIServiceError.httpStatus(let code, _):
            return [429, 500, 502, 503, 504].contains(code)
        case AIServiceError.network(let underlying):
            if let urlError = underlying as? URLError {
                switch urlError.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                     .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                    return true
                default:
                    return false
                }
            }
            return false
        default:
            return false
        }
    }

    /// Compact page summary for the ephemeral per-request injection: title,
    /// URL, and the first ~1200 characters of visible text. Nil when there is
    /// no real web page (new tab, blank) or the user turned the feature off.
    private func fetchCompactPageContext() async -> String? {
        guard preference.autoPageContext, let wv = activeWebView,
              let url = wv.url, url.scheme == "http" || url.scheme == "https" else { return nil }
        let js = """
        (function(){
            var text = (document.body && document.body.innerText || '').replace(/\\s+/g, ' ').trim();
            return JSON.stringify({ title: document.title || '', text: text.substring(0, 1200) });
        })()
        """
        let raw: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            wv.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
        guard let data = raw?.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let text = obj["text"], !text.isEmpty else { return nil }
        let title = obj["title"] ?? ""
        return "[Current page] \(title) — \(url.absoluteString)\n\(text)"
    }

    /// The message array actually sent to the model: the stored conversation,
    /// compacted to fit the context budget, plus the fresh page context.
    /// Neither transformation is persisted — `messages` stays intact.
    private func buildRequestMessages() async -> [AIMessage] {
        var request = Self.compactForContext(messages)
        // L0+L1+L2 memory goes first so compaction above can never drop it.
        if let memoryBlock = AgentMemoryStore.shared.promptBlock(excluding: conversationId) {
            request.insert(AIMessage(role: .system, content: memoryBlock), at: 0)
        }
        if let pageContext = await fetchCompactPageContext() {
            request.append(AIMessage(role: .system, content: pageContext))
        }
        let skills = SkillStore.shared.skills
        if !skills.isEmpty {
            let lines = skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
            request.append(AIMessage(role: .system, content: """
            [Installed skills — call useSkill(name) to load full instructions             before performing a matching task]
            \(lines)
            """))
        }
        return request
    }

    /// Drops the OLDEST user-started conversation blocks while the estimated
    /// context size exceeds the budget. A block runs from a user message up
    /// to the next user message, so assistant tool_calls and their tool
    /// results always stay together — OpenAI's tool-call→tool-result pairing
    /// is never broken. The final block is never dropped.
    static func compactForContext(_ messages: [AIMessage], budget: Int = 160_000) -> [AIMessage] {
        func size(_ m: AIMessage) -> Int {
            (m.content?.count ?? 0)
                + (m.toolCalls?.reduce(0) { $0 + $1.function.arguments.count + $1.function.name.count } ?? 0)
        }
        let sizes = messages.map(size)
        var total = sizes.reduce(0, +)
        guard total > budget else { return messages }

        let starts = messages.indices.filter { messages[$0].role == .user }
        guard starts.count > 1 else { return messages }

        var keepStart = 0
        for (i, s) in starts.enumerated() {
            if total <= budget { break }
            if i == starts.count - 1 { break }   // never drop the final block
            let end = i + 1 < starts.count ? starts[i + 1] : messages.count
            total -= (s..<end).reduce(0) { $0 + sizes[$1] }
            keepStart = end
        }
        guard keepStart > 0 else { return messages }
        return Array(messages[keepStart...])
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
            var assistantMsg: AIMessage?
            var hasContent = false
            var lastTokenTime = Date()

            // Consumes one model stream into the conversation. Nested func so
            // the transient-error retry below can re-run it on a fresh stream
            // without duplicating the event handling.
            func runStream() async throws {
                let active = makeActiveProvider()
                lastProviderUsed = active.viaLabel
                let request = await buildRequestMessages()
                let stream = active.provider.stream(
                    messages: request,
                    tools: BrowserToolProvider.toolDefs + MCPStore.shared.toolDefs,
                    prefs: preference
                )
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
            }

            func fail(_ error: Error) {
                let errorText = "Error: \(error.localizedDescription)"
                if let idx = assistantMsg.flatMap({ m in messages.firstIndex(where: { $0.id == m.id }) }) {
                    messages[idx].content = errorText
                    messages[idx].toolCalls = nil
                } else {
                    messages.append(AIMessage(role: .assistant, content: errorText))
                }
                streamingVersion += 1
            }

            do {
                try await runStream()
            } catch let error where assistantMsg == nil && Self.isTransientStreamError(error) {
                // ONE automatic retry for transient failures (rate limit,
                // 5xx, dropped/timed-out connection) — allowed only when
                // nothing has streamed yet, so a retry can never duplicate
                // partial output.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if isCancelled { return }
                do {
                    try await runStream()
                } catch {
                    fail(error)
                    return
                }
            } catch {
                fail(error)
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

        // Background memory housekeeping (L1 facts + L2 summary) — never
        // blocks or fails the turn.
        await runMemoryHousekeeping()
    }

    /// Extracts durable facts and refreshes the conversation summary once
    /// enough NEW turns accumulated since the last pass.
    private func runMemoryHousekeeping() async {
        guard preference.memoryLearning, !isCancelled,
              messages.contains(where: { $0.role == .user }),
              messages.contains(where: { $0.role == .assistant }) else { return }

        if messages.count - memoryProcessedCount >= 4 {
            await MemoryExtractor.extractFacts(
                preference: preference,
                memory: AgentMemoryStore.shared,
                messages: Array(messages.suffix(14))
            )
        }
        if messages.count >= 12, let conversationId = conversationId {
            await MemoryExtractor.summarize(
                preference: preference,
                memory: AgentMemoryStore.shared,
                conversationId: conversationId,
                messages: Array(messages.suffix(40))
            )
        }
        memoryProcessedCount = messages.count
    }

    // MARK: - Tool approval gating

    /// Decides whether a tool call may run. Returns the outcome — the loop
    /// then either executes the tool, appends a denial, or (if cancelled)
    /// returns. `.readonly` tools and whitelisted tools bypass the prompt.
    private func gate(toolCall: AIToolCall, risk: ToolRisk) async -> ApprovalOutcome {
        if isCancelled { return .denied }

        // FULL ACCESS: the user explicitly delegated every tool decision —
        // including dangerous-tier executeJS — so nothing pauses.
        if fullAccess { return .allowedOnce }

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
