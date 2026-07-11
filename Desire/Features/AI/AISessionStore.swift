import Combine
import WebKit

enum AIQuickAction: CaseIterable {
    case summarize
    case askAboutPage
    case translate

    var title: String {
        switch self {
        case .summarize: String(localized: "Summarize")
        case .askAboutPage: String(localized: "Ask about Page")
        case .translate: String(localized: "Translate")
        }
    }

    var icon: String {
        switch self {
        case .summarize: "text.alignleft"
        case .askAboutPage: "text.bubble"
        case .translate: "translate"
        }
    }

    var prompt: String {
        switch self {
        case .summarize: String(localized: "Summarize the current page in detail")
        case .askAboutPage: String(localized: "I'm looking at this page and want to ask:")
        case .translate: String(localized: "Translate this page to Chinese")
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

    var preference = AIPreferenceStore()
    private let toolProvider = BrowserToolProvider()
    private weak var webView: WKWebView?
    private var isCancelled = false
    weak var conversationStore: ConversationStore?

    /// Tools the user has whitelisted with "Always Allow". Persisted across
    /// launches. `.dangerous` tools are never honored here — they always
    /// prompt. Stored as the raw tool-name strings.
    private let allowedToolsKey = "aiAllowedTools"
    private var allowedTools: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: allowedToolsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: allowedToolsKey)
        }
    }

    /// Soft cap on agent loop iterations to prevent runaway execution.
    /// Replaces the old hardcoded `0..<20` limit. Configurable later.
    private let maxIterations = 50

    func setWebView(_ wv: WKWebView?) {
        webView = wv
    }

    func configureStores(
        tabManager: TabManager?,
        bookmarkStore: BookmarkStore?,
        historyStore: HistoryStore?,
        contentBlocker: ContentBlocker?,
        readingListStore: ReadingListStore?,
        downloadStore: DownloadStore?,
        siteSettingsStore: SiteSettingsStore?,
        settings: Settings?,
        videoAdBlocker: VideoAdBlocker?,
        pluginStore: PluginStore? = nil,
        elementBlockStore: ElementBlockStore? = nil,
        tabGroupStore: TabGroupStore? = nil,
        quickDialStore: QuickDialStore? = nil
    ) {
        toolProvider.tabManager = tabManager
        toolProvider.bookmarkStore = bookmarkStore
        toolProvider.historyStore = historyStore
        toolProvider.contentBlocker = contentBlocker
        toolProvider.readingListStore = readingListStore
        toolProvider.downloadStore = downloadStore
        toolProvider.siteSettingsStore = siteSettingsStore
        toolProvider.settings = settings
        toolProvider.videoAdBlocker = videoAdBlocker
        toolProvider.pluginStore = pluginStore
        toolProvider.elementBlockStore = elementBlockStore
        toolProvider.tabGroupStore = tabGroupStore
        toolProvider.quickDialStore = quickDialStore
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
        Task { await processLoop() }
    }

    func performQuickAction(_ action: AIQuickAction) {
        switch action {
        case .summarize, .translate:
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

    func cancel() {
        isCancelled = true
        isProcessing = false
        currentAction = nil
        awaitingQuestion = false
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
    }

    func loadConversation(_ id: UUID) {
        guard let conv = conversationStore?.conversation(for: id) else { return }
        messages = conv.messages
        conversationId = conv.id
        conversationTitle = conv.title
        awaitingQuestion = false
        currentAction = nil
        streamingVersion += 1
    }

    private func saveCurrentConversation() {
        guard let store = conversationStore else { return }
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
        store.save(conv)
    }

    private func fetchPageText() async -> String {
        guard let wv = webView else { return "" }
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
            // Routed through `preference.provider` (a `ModelProvider`)
            // instead of `AIService` directly, so Foundation Models /
            // Ollama / a routing provider can be swapped in without
            // touching the agent loop.
            let stream = preference.provider.stream(
                messages: messages,
                tools: BrowserToolProvider.toolDefs,
                prefs: preference
            )

            var assistantMsg: AIMessage?
            var hasContent = false

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
                let result = await toolProvider.execute(tc, in: webView ?? WKWebView())
                messages.append(AIMessage(
                    role: .tool,
                    content: result,
                    toolCallId: tc.id,
                    toolName: tc.function.name
                ))
            }
            currentAction = nil
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
        if risk != .dangerous && allowedTools.contains(toolCall.function.name) {
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
                var current = allowedTools
                current.insert(approval.toolCall.function.name)
                allowedTools = current
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

/// The user's decision on a tool approval prompt. Returned by the UI.
enum ApprovalDecision {
    case allowOnce
    case alwaysAllow
    case deny
}

/// Internal outcome the agent loop acts on. Distinct from
/// `ApprovalDecision` because whitelisted / readonly tools resolve to
/// `.allowedOnce` without ever prompting the user.
enum ApprovalOutcome {
    case allowedOnce
    case allowedAlways
    case denied
}

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
