import AppKit
import Combine
import os
import WebKit

enum AgentQuickAction: CaseIterable {
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
class AgentSessionStore: ObservableObject {
    @Published var messages: [AgentMessage] = []
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
    /// Wall-clock start of the current processing run (drives the elapsed
    /// timer in the panel status line).
    @Published var processingStartedAt: Date?
    @Published var streamingTokensPerSecond: Double = 0

    /// AI preferences (model, endpoint, API key, provider kind, ...). Owned
    /// by `AgentState` and injected here so the Settings window and the agent
    /// loop share the exact same instance — edits in Settings reach the live
    /// agent, and `routingLockedToCloud` is visible everywhere.
    let preference: AgentPreferenceStore
    /// Conversation history store. Strongly held by `AgentState`; injected here
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
    /// Shutdown-diagnostics peek: whether the loop task has been cancelled.
    var isLoopCancelled: Bool { loopTask?.isCancelled ?? true }
    /// True after `clear()` until a conversation is loaded or a message is
    /// sent — gates `resumeLatestConversation` so a deliberate new chat
    /// stays blank when the panel is reopened.
    private var isNewChatIntentional = false

    /// A message typed while a turn was already running. Delivered to the
    /// model automatically when the running turn finishes. `onTurnFinish`
    /// rides along so an EXTERNAL delivery (scheduled task) that got queued
    /// has its completion handler bound to ITS turn, not to whichever turn
    /// happens to end first.
    struct QueuedMessage: Identifiable {
        let id = UUID()
        let text: String
        let images: [String]?
        var onTurnFinish: ((TurnOutcome) -> Void)? = nil
    }

    /// Input typed mid-turn, flushed by `processLoop` when the turn ends
    /// cleanly. The panel renders a queue strip from this.
    /// 更新"上下文占用比例"。口径与 `compactForContext` 相同（字符数 / 预算）；
    /// 按 (条数, 末条长度) 记忆，流式期间每 80ms 只多一次 O(n) 轻扫。
    private func updateContextFraction() {
        let key = "\(messages.count)-\(messages.last?.content?.count ?? 0)"
        guard key != contextFractionStamp else { return }
        contextFractionStamp = key
        var total = 0
        for m in messages {
            total += m.content?.count ?? 0
            for tc in m.toolCalls ?? [] { total += tc.function.arguments.count + tc.function.name.count }
        }
        contextFraction = min(1.0, Double(total) / Double(Self.contextBudget))
    }

    @Published private(set) var queuedMessages: [QueuedMessage] = []
    /// Set when a turn's model stream failed — gates queue flushing so a
    /// broken provider can't rapid-fire the whole queue into errors.
    private var turnFailed = false
    /// Error text of the most recent failed turn (scheduler run records).
    private var lastTurnErrorText: String?
    /// Result of a finished turn, delivered to registered handlers (the
    /// scheduler's run records subscribe to learn how scheduled prompts ended).
    struct TurnOutcome {
        let success: Bool
        let error: String?
    }
    private var turnFinishHandlers: [(TurnOutcome) -> Void] = []
    func addTurnFinishHandler(_ handler: @escaping (TurnOutcome) -> Void) {
        turnFinishHandlers.append(handler)
    }

    /// Registry id (multi-window addressing via the automation bridge).
    let registrationID = UUID()

    init(preference: AgentPreferenceStore, conversationStore: ConversationStore) {
        self.preference = preference
        self.conversationStore = conversationStore
        fullAccess = UserDefaults.standard.bool(forKey: "aiFullAccess")
        // Newest session wins scheduled-task delivery (multi-window).
        AgentScheduler.shared.deliveryTarget = self
        // Registry for per-window addressing (0.1.8).
        AgentScheduler.shared.registerSession(self)
    }

    /// Entry point for `AgentScheduler` firings: starts (or queues) a turn
    /// carrying the scheduled prompt, tagged so the conversation shows
    /// where it came from. `onTurnFinish` fires when THAT turn ends —
    /// either the one started here or the queued one when the loop flushes.
    func deliverScheduled(_ prompt: String, from taskName: String,
                          onTurnFinish: ((TurnOutcome) -> Void)? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isProcessing else {
            queuedMessages.append(QueuedMessage(
                text: "[定时任务 · \(taskName)] \(trimmed)", images: nil,
                onTurnFinish: onTurnFinish))
            return
        }
        if let onTurnFinish { turnFinishHandlers.append(onTurnFinish) }
        sendMessage("[定时任务 · \(taskName)] \(trimmed)")
    }

    /// Soft cap on agent loop iterations to prevent runaway execution.
    /// User-configurable in Settings → Agent (default 50).
    private var maxIterations: Int { preference.maxLoopIterations }

    /// Pauses the running loop between model/tool steps — the user can
    /// inspect mid-task state and resume without losing the plan.
    @Published var isPaused = false

    /// Token usage accumulated for the loaded conversation (provider-
    /// reported where available; Foundation Models reports nothing).
    @Published private(set) var usagePromptTokens = 0
    @Published private(set) var usageCompletionTokens = 0
    /// **最近一次**请求的 prompt token 数：累计值对用户没意义，他要的是"现在多满"。
    @Published private(set) var lastPromptTokens = 0
    /// 当前对话占用 `compactForContext` 预算的比例（同一口径：字符数 / 160k）。
    /// 模型开始返回空、或自动压缩要生效之前，用户至少能看到它在逼近上限。
    @Published private(set) var contextFraction: Double = 0
    private var contextFractionStamp = ""
    /// 上下文预算，与 `compactForContext` 的默认值一致（改一处即可）。
    static let contextBudget = 160_000

    /// 自评（reflection）提示词：只**审查**轨迹，不许执行工具、不许续写任务。
    /// 工具 `reflect` 与回合收尾的自动自评共用它。
    static let critiquePrompt = """
    你是这次任务的自评者（reviewer）。下面给你目标和它**实际**的执行轨迹（工具调用与观察）。
    不要执行任何工具，也不要继续完成任务——只做审查，按下面四问回答：
    1) 有没有"没验证就宣布完成"的结论？证据是什么？
    2) 有没有失败、被跳过或被吞掉的步骤没告诉用户？
    3) 有没有更简单或更可靠的做法？
    4) 有没有漏掉用户明确提出的要求？
    最多 4 行，一行一条；确实没问题就只回一句"未发现问题"。
    """
    /// Message count already digested by background memory extraction —
    /// gates the next extraction until enough NEW turns accumulate.
    private var memoryProcessedCount = 0
    /// Set once a model-generated conversation title exists (the fallback
    /// title is just the truncated first message).
    private var titleGenerated = false

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
        // the tab content. The same-webview no-op guard keeps identical
        // renders from republishing; a REAL change (tab switch) must still
        // not publish synchronously — that happens inside the view update
        // and trips "Publishing changes from within view updates". Hop to
        // the next main-actor tick, where publishing is legal.
        guard webView !== wv else { return }
        webView = wv
        Task { @MainActor [weak self] in
            self?.refreshContextLabel()
        }
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
        // Tab Crew（0.3.1）：作业组全部落定 → 把各子任务报告聚合成一条
        // 提示送回领队消息流（领队忙则排队，空闲则直接开一轮聚合播报）。
        AgentCrewStore.shared.onCrewSettled = { [weak self] crew in
            guard let self else { return }
            var sections: [String] = []
            for t in crew.tasks {
                switch t.state {
                case .done:
                    sections.append("### Subtask [\(t.index)] \(t.instruction.prefix(60))\n\(t.result ?? "")")
                case .failed, .cancelled:
                    sections.append("### Subtask [\(t.index)] FAILED: \(t.result ?? t.state.rawValue)")
                case .pending, .running:
                    break
                }
            }
            let prompt = """
            [Crew "\(crew.objective)" finished — \(crew.completedCount)/\(crew.tasks.count) subtasks succeeded]

            \(sections.joined(separator: "\n\n"))

            Aggregate these subtask reports into the final answer for the user now.
            """
            if !isProcessing {
                sendMessage(prompt)
            } else {
                queuedMessages.append(QueuedMessage(text: prompt, images: nil))
            }
        }
    }

    /// `recordHistory`：把这条输入记进该对话的输入历史（面板输入框 ↑/↓ 翻阅的那份）。
    /// 默认记录——**用户输入**才会走这里；桥/调度等自动化调用显式传 false，
    /// 免得把机器人的提示词混进用户的历史。
    func sendMessage(_ text: String, images: [String]? = nil, recordHistory: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !(images ?? []).isEmpty else { return }
        if recordHistory { rememberInput(trimmed) }
        // A second concurrent loop would interleave appends into `messages`
        // and corrupt tool-call/result pairing — queue instead.
        guard !isProcessing else {
            queuedMessages.append(QueuedMessage(text: trimmed, images: images))
            return
        }
        messages.append(AgentMessage(role: .user, content: trimmed, images: images))
        if conversationId == nil {
            conversationTitle = String(trimmed.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        saveCurrentConversation()
        isProcessing = true
        isCancelled = false
        refreshContextLabel()
        streamingTokenCount = 0
        streamingTokensPerSecond = 0
        processingStartedAt = Date()
        loopTask = Task { await processLoop() }
    }

    /// Removes everything waiting in the send queue (queue strip ✕ button).
    func clearQueuedMessages() {
        queuedMessages.removeAll()
    }

    /// 移除队列里的某一条（队列条每行右侧的 ✕）。此前只能整条清空。
    func removeQueued(id: UUID) {
        queuedMessages.removeAll { $0.id == id }
    }

    func performQuickAction(_ action: AgentQuickAction) {
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
                messages.append(AgentMessage(role: .user, content: context))
            }
        }
    }

    func sendFollowUp(_ text: String) {
        awaitingQuestion = false
        sendMessage(text)
    }

    func addContext(html: String, selector: String) {
        let context = "<\(selector)>: \(html.prefix(1000))"
        messages.append(AgentMessage(role: .user, content: "[Selected element]\n\(context)"))
    }

    /// Adds the user's text selection as context; the next typed message can
    /// reference it ("翻译一下" / "解释第二段" …).
    func addSelectedTextContext(_ text: String) {
        messages.append(AgentMessage(role: .user, content: "[Selected text]\n\(text)"))
    }

    func cancel() {
        isCancelled = true
        isProcessing = false
        currentAction = nil
        awaitingQuestion = false
        // Stop means stop: drop anything still waiting to be sent.
        queuedMessages.removeAll()
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
        // Same for an in-flight askUser: without this the cancelled loop
        // task stays suspended on its continuation forever (leak + the UI
        // question card never clears).
        UserPromptCenter.shared.cancel()
        isPaused = false
    }

    /// Pauses the running turn at the next checkpoint (before the next
    /// model call or tool execution). No-op when idle.
    func pause() {
        guard isProcessing else { return }
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    private func waitWhilePaused() async {
        while isPaused && !isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Re-runs the LAST user message: drops every message after it (the
    /// assistant reply and any tool traffic) and restarts the agent loop.
    func regenerate() {
        guard !isProcessing,
              let lastUser = messages.lastIndex(where: { $0.role == .user }),
              lastUser < messages.count - 1 else { return }
        messages.removeSubrange((lastUser + 1)...)
        AgentPlanStore.shared.clear()
        processingStartedAt = Date()
        isProcessing = true
        isCancelled = false
        refreshContextLabel()
        streamingTokenCount = 0
        streamingTokensPerSecond = 0
        loopTask = Task { await processLoop() }
    }

    /// 本对话的输入历史（面板输入框 ↑/↓ 翻阅）。**按对话**记录并随会话落盘，
    /// 最新在末尾，最多 100 条；相邻重复不重复记录。
    @Published private(set) var inputHistory: [String] = []
    private let inputHistoryCap = 100

    /// 记一条用户输入（面板提交时调用）。
    func rememberInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard inputHistory.last != trimmed else { return }
        inputHistory.append(trimmed)
        if inputHistory.count > inputHistoryCap {
            inputHistory.removeFirst(inputHistory.count - inputHistoryCap)
        }
        saveCurrentConversation()
    }

    /// 从外部往会话追加一条 system 备注（后台任务完成等）。**不触发**新一轮模型
    /// 调用：面板里不渲染 system 消息（`AgentMessageBubble` 的 `.system` 是
    /// EmptyView），但下一轮请求会带上它，模型因此知道下载/导出已经结束。
    func appendExternalNote(_ text: String) {
        messages.append(AgentMessage(role: .system, content: text))
        streamingVersion += 1
        saveCurrentConversation()
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
        // The next conversation must be able to earn its own generated title.
        titleGenerated = false
        queuedMessages.removeAll()
        isPaused = false
        usagePromptTokens = 0
        usageCompletionTokens = 0
        AgentPlanStore.shared.clear()
        UserPromptCenter.shared.cancel()
        messages.removeAll()
        conversationId = nil
        conversationTitle = nil
        inputHistory.removeAll()   // 新对话从空历史开始
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
        inputHistory = conv.inputHistory ?? []   // 每个对话记自己的输入历史
        awaitingQuestion = false
        currentAction = nil
        isNewChatIntentional = false
        // Queued input belonged to the previous conversation's turn.
        queuedMessages.removeAll()
        isPaused = false
        usagePromptTokens = 0
        usageCompletionTokens = 0
        memoryProcessedCount = messages.count
        // The stored title is final — either generated earlier or renamed by
        // the user in the history list. Never let title generation clobber it.
        titleGenerated = true
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
        let persistedMessages = messages.map { msg -> AgentMessage in
            var copy = msg
            copy.imageDataURIs = nil
            return copy
        }
        let conv = Conversation(id: id, title: title, createdAt: Date(), updatedAt: Date(), messages: persistedMessages, inputHistory: inputHistory)
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
        case AgentServiceError.httpStatus(let code, _):
            return [429, 500, 502, 503, 504].contains(code)
        case AgentServiceError.network(let underlying):
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

    /// Drops the OLDEST user-started conversation blocks while the estimated
    /// context size exceeds the budget. A block runs from a user message up
    /// to the next user message, so assistant tool_calls and their tool
    /// results always stay together — the provider's tool-call→tool-result
    /// pairing is never broken. The final block is never dropped.
    static func compactForContext(_ messages: [AgentMessage], budget: Int = 160_000) -> [AgentMessage] {
        func size(_ m: AgentMessage) -> Int {
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

    /// The message array actually sent to the model: the stored conversation,
    /// compacted to fit the context budget, plus the fresh page context.
    /// Neither transformation is persisted — `messages` stays intact.
    private func buildRequestMessages() async -> [AgentMessage] {
        var request = Self.compactForContext(messages)

        // 会话里可能存在"带外备注"（下载完成、导出结束…，role == .system，见
        // `appendExternalNote`）。**OpenAI 兼容服务要求 system 只能出现在开头**，
        // 夹在对话中间会被直接拒绝（实测 amd 网关：`System message must be at the
        // beginning`）。所以把它们从消息流里摘出来，并入开头那条组合 system 提示。
        let notes = request.compactMap { $0.role == .system ? $0.content : nil }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        request.removeAll { $0.role == .system }

        // One composed system prompt with ordered layers — identity (the
        // user's editable prompt), L0-L2 memory, the skills list, the
        // workspace path, and a FRESH per-iteration page summary. Injected
        // at position 0 after compaction so it can never be dropped, and
        // never persisted into the stored conversation.
        let identity = {
            let stored = preference.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? AgentPreferenceStore.defaultPrompt : stored
        }()
        let currentHost = await MainActor.run { () -> String? in
            toolSurface?.tabManager?.selectedTab?.browser.webView.url?.host
        }
        let memoryBlock = AgentMemoryStore.shared.promptBlock(
            excluding: conversationId,
            currentHost: currentHost
        )
        let skills = SkillStore.shared.skills.map { ($0.name, $0.description) }
        let pageContext = await fetchCompactPageContext()
        let composed = AgentPromptBuilder.compose(.init(
            identity: identity,
            memoryBlock: memoryBlock,
            skills: skills,
            tools: BrowserToolProvider.promptInventory(for: BrowserToolProvider.toolDefs + MCPStore.shared.toolDefs),
            workspacePath: SystemCommandStore.shared.workingDirectory.path,
            downloadsPath: AgentPromptBuilder.downloadsPath,
            ffmpegAvailable: FFmpegExporter.isAvailable,
            ffmpegPath: FFmpegExporter.locate()?.path,
            pageContext: pageContext
        ))
        let notesBlock = notes.isEmpty
            ? ""
            : "\n\n## Session notes\n" + notes.map { "- \($0)" }.joined(separator: "\n")
        request.insert(AgentMessage(role: .system, content: composed + notesBlock), at: 0)
        return request
    }

    private func processLoop() async {
        defer {
            isProcessing = false
            currentAction = nil
            processingStartedAt = nil
            if !isCancelled, preference.completionSound { NSSound(named: "Glass")?.play() }
        }

        // Drive turns back-to-back, flushing messages the user typed while
        // a turn was running (queued by `sendMessage`).
        while !isCancelled {
            turnFailed = false
            lastTurnErrorText = nil
            await runTurn()
            // Turn finished — hand the outcome to registered handlers
            // (scheduler run records for scheduled prompts).
            let outcome = TurnOutcome(success: !turnFailed, error: lastTurnErrorText)
            let handlers = turnFinishHandlers
            turnFinishHandlers.removeAll()
            handlers.forEach { $0(outcome) }
            // Flush the queue only after a clean turn: a broken provider
            // would otherwise burn the whole queue in rapid error bursts.
            guard !turnFailed, !isCancelled, let next = queuedMessages.first else { break }
            queuedMessages.removeFirst()
            // A queued external delivery carries its own turn-finish hook —
            // attach it so the coming turn reports to the right run record.
            if let handler = next.onTurnFinish {
                turnFinishHandlers.append(handler)
            }
            messages.append(AgentMessage(role: .user, content: next.text, images: next.images))
            saveCurrentConversation()
            streamingTokenCount = 0
            streamingTokensPerSecond = 0
            processingStartedAt = Date()
        }

        // **先把"忙碌"交还给界面，再做收尾**：标题生成与记忆整理都是额外的模型
        // 调用，此前它们跑在 `isProcessing == true` 期间，于是正文早就渲染完了、
        // 面板却一直显示"流式中"（实测反馈："消息都渲染完了还在流式输出"）。
        // 收尾仍在同一个 task 里串行跑（不与下一轮抢 memoryProcessedCount）。
        isProcessing = false
        currentAction = nil

        // Cancelled turns skip the post-work: a title generation would spend
        // one more model call on a conversation the user just walked away from.
        if !isCancelled {
            await generateTitleIfNeeded()
        }

        // Background memory housekeeping (L1 facts + L2 summary) — never
        // blocks or fails the turn.
        if !isCancelled {
            await runMemoryHousekeeping()
        }

        // 机械核验（0 次模型调用，先跑：它是客观事实，且立刻能被用户看到）。
        if !isCancelled {
            runMechanicalVerification()
        }

        // 自动自评（同上：在"忙碌"交还界面之后跑；失败静默，不影响回合结论）。
        if !isCancelled {
            await runSelfReviewIfNeeded()
        }
    }

    /// One model→tools→model turn. Returns when the model stops calling
    /// tools, errors out, or the iteration cap is hit.
    private func runTurn() async {
        // AgentRuntime v2: budget-based loop replaces the old hardcoded
        // `0..<20` iteration cap. The soft limit (`maxIterations`) prevents
        // runaway execution while allowing genuinely long multi-step tasks.
        var iterations = 0
        var hitIterationCap = false

        while !isCancelled && iterations < maxIterations {
            iterations += 1
            await waitWhilePaused()

            // Tool definitions must be sent on EVERY call in a tool-use
            // conversation: the second call sends back tool results, and
            // the model still needs to know the tool schemas to decide
            // what to do next (or to make another tool call).
            //
            // Routed through `activeProvider` (a `ModelProvider`) instead of
            // `AgentService` directly, so Foundation Models / Ollama / a routing
            // provider can be swapped in without touching the agent loop.
            // When `providerKind == .routing`, each call may target a
            // different concrete provider and report it via lastProviderUsed.
            // Consumes one model stream into the conversation. Nested func so
            // the transient-error retry below can re-run it on a fresh stream
            // without duplicating the event handling.
            //
            // Token counters are @Published — writing them per token event
            // republished the whole session store at token frequency (100+/s)
            // and re-evaluated the entire panel body. They now advance only
            // inside the throttled flush (~12 fps), which is also the display
            // granularity of the status line.
            var assistantMsg: AgentMessage?
            var hasContent = false
            var pendingTokenCount = 0
            var rateWindowStart = Date()

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
                // UI flush state: per-token array writes + view
                // invalidations dominate long streams, so the tail message
                // is published at ~12 fps instead of per token.
                var lastFlush = Date.distantPast
                func flushTail() {
                    updateContextFraction()
                    // 按 **id** 找回尾部消息，不用 append 时记下的下标：流式中途
                    // 会话被清空/切换时，那个下标会指向别的消息（把 token 写进
                    // 无关消息），数组变短后还可能越界。
                    if let msg = assistantMsg,
                       let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                        messages[idx] = msg
                    }
                    streamingVersion += 1
                }
                for try await event in stream {
                    if isCancelled { flushTail(); return }
                    switch event {
                    case .text(let delta):
                        if assistantMsg == nil {
                            assistantMsg = AgentMessage(role: .assistant, content: "")
                            messages.append(assistantMsg!)
                        }
                        assistantMsg!.content = (assistantMsg!.content ?? "") + delta
                        hasContent = true
                        pendingTokenCount += 1
                        let now = Date()
                        if now.timeIntervalSince(lastFlush) >= 0.08 {
                            lastFlush = now
                            streamingTokenCount += pendingTokenCount
                            let dt = now.timeIntervalSince(rateWindowStart)
                            if dt > 0 { streamingTokensPerSecond = Double(pendingTokenCount) / dt }
                            pendingTokenCount = 0
                            rateWindowStart = now
                            flushTail()
                        }
                    case .reasoning(let delta):
                        // 思考过程：与正文同一条节流路径落进同一条消息（面板里折叠展示）。
                        // **不算 hasContent**——只回了思考、没有正文，仍然算空回合（会提示）。
                        if assistantMsg == nil {
                            assistantMsg = AgentMessage(role: .assistant, content: "")
                            messages.append(assistantMsg!)
                        }
                        assistantMsg!.reasoning = (assistantMsg!.reasoning ?? "") + delta
                        pendingTokenCount += 1
                        let reasoningNow = Date()
                        if reasoningNow.timeIntervalSince(lastFlush) >= 0.08 {
                            lastFlush = reasoningNow
                            streamingTokenCount += pendingTokenCount
                            let dt = reasoningNow.timeIntervalSince(rateWindowStart)
                            if dt > 0 { streamingTokensPerSecond = Double(pendingTokenCount) / dt }
                            pendingTokenCount = 0
                            rateWindowStart = reasoningNow
                            flushTail()
                        }
                    case .toolCall(let call):
                        if assistantMsg == nil {
                            assistantMsg = AgentMessage(role: .assistant, content: "")
                            messages.append(assistantMsg!)
                        }
                        assistantMsg!.toolCalls = (assistantMsg!.toolCalls ?? []) + [call]
                        if let idx = messages.lastIndex(where: { $0.id == assistantMsg!.id }) {
                            messages[idx] = assistantMsg!
                            streamingVersion += 1
                        }
                        hasContent = true
                    case .usage(let prompt, let completion):
                        usagePromptTokens += prompt
                        usageCompletionTokens += completion
                        if prompt > 0 { lastPromptTokens = prompt }
                    }
                }
                // Publish the tail the throttle may have held back.
                flushTail()
            }

            func fail(_ error: Error) {
                turnFailed = true
                lastTurnErrorText = error.localizedDescription
                let errorText = "Error: \(error.localizedDescription)"
                if let idx = assistantMsg.flatMap({ m in messages.firstIndex(where: { $0.id == m.id }) }) {
                    messages[idx].content = errorText
                    messages[idx].toolCalls = nil
                } else {
                    messages.append(AgentMessage(role: .assistant, content: errorText))
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

            guard hasContent, let msg = assistantMsg else {
                // **绝不能"什么都不显示"**：模型返回空内容时此前直接 return，
                // 用户发完消息像石沉大海（实测："经过几次工具失败后再发消息没有
                // 回复了"）。把空回合变成一条可见的、说清原因的失败。
                let reasoningOnly = !(assistantMsg?.reasoning?.isEmpty ?? true)
                let note = reasoningOnly
                    ? String(localized: "The model only produced its thinking and never wrote an answer. Try asking again, or switch model/service in Settings.")
                    : String(localized: "The model returned an empty response — nothing was generated. Usually the context is too long for this service or the endpoint failed upstream. Try /new to start a fresh conversation, or switch model/service in Settings.")
                messages.append(AgentMessage(role: .assistant, content: "⚠️ " + note))
                turnFailed = true
                lastTurnErrorText = note
                streamingVersion += 1
                return
            }

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
                await waitWhilePaused()
                let risk = ToolRisk.classify(tc.function.name)

                let decision = await gate(toolCall: tc, risk: risk)
                switch decision {
                case .denied:
                    // Tell the model the user declined, so it can adapt.
                    messages.append(AgentMessage(
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
                let startedAt = Date()
                let result: String
                if tc.function.name == "spawnSubagent" {
                    // Subagents run here, not in BrowserToolProvider — they
                    // need the loop's approval gate and provider stack.
                    result = await runSubagent(argumentsJSON: tc.function.arguments)
                } else {
                    result = await toolProvider.execute(tc, in: activeWebView ?? WKWebView())
                }
                messages.append(AgentMessage(
                    role: .tool,
                    content: result,
                    toolCallId: tc.id,
                    toolName: tc.function.name,
                    // 耗时记在这条工具消息上：轨迹导出要用，而它是唯一派不出来的一项。
                    toolDurationMs: Date().timeIntervalSince(startedAt) * 1000
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
            messages.append(AgentMessage(
                role: .assistant,
                content: "⚠️ Reached the maximum number of steps (\(maxIterations)). Stopping to avoid runaway execution."
            ))
            streamingVersion += 1
            saveCurrentConversation()
        }
    }

    // MARK: - Subagent

    /// Live progress of one delegated subagent (rendered in the panel strip).
    struct SubagentProgress: Identifiable {
        let id = UUID()
        let label: String
        var step: Int = 0
        var maxSteps: Int
        var currentTool: String?
    }

    /// Currently running subagents.
    @Published private(set) var runningSubagents: [SubagentProgress] = []

    /// Serializes approval prompts: parallel subagents can request
    /// approvals simultaneously, but there is one approval UI. Check and
    /// set happen with no await between — atomic on the main actor.
    private var approvalSlotBusy = false

    private func acquireApprovalSlot() async {
        while approvalSlotBusy {
            if isCancelled { return }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        approvalSlotBusy = true
    }

    /// Window-global tools a subagent must not touch: they would steal the
    /// shared window's tab selection or flip app-wide toggles while other
    /// agents (or the user) are working.
    private static let subagentDisabledTools: Set<String> = [
        "newTab", "switchTab", "closeTab", "closeOtherTabs", "reopenLastClosedTab",
        "duplicateTab", "toggleSidebar", "setSearchEngine", "toggleAdBlocking",
        "toggleTrackingProtection", "clearHistory", "startRecording",
        "stopRecording", "printPage", "toggleResponsiveMode",
    ]

    private static var subagentAllowedToolDefs: [AgentToolDef] {
        BrowserToolProvider.toolDefs.filter {
            $0.function.name != "spawnSubagent" && !subagentDisabledTools.contains($0.function.name)
        }
    }

    /// Runs a delegated sub-task — or a fan-out of up to 3 in parallel — in
    /// a fresh, ephemeral context: own message array and step cap, but the
    /// same tools, approval gate, and provider stack. Only the final
    /// report(s) return to the parent; transcripts are not persisted.
    private func runSubagent(argumentsJSON: String) async -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Missing task"
        }

        // Fan-out: "tasks": [{task, maxSteps}, …] — one tab + one loop each.
        if let rawJobs = args["tasks"] as? [[String: Any]], rawJobs.count > 1 {
            let jobs = rawJobs.prefix(3).compactMap { item -> (task: String, maxSteps: Int)? in
                guard let t = (item["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !t.isEmpty else { return nil }
                return (t, max(3, min(item["maxSteps"] as? Int ?? 10, 12)))
            }
            guard !jobs.isEmpty else { return "No valid tasks in the tasks array" }
            return await runParallelSubagents(jobs: Array(jobs))
        }

        guard let task = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty else {
            return "Missing task"
        }
        let maxSteps = max(3, min(args["maxSteps"] as? Int ?? 10, 15))
        let progress = SubagentProgress(label: Self.progressLabel(task), maxSteps: maxSteps)
        runningSubagents.append(progress)
        defer { runningSubagents.removeAll { $0.id == progress.id } }
        return await runSubagentLoop(
            task: task, maxSteps: maxSteps, webView: nil, progressID: progress.id
        )
    }

    /// Parallel dispatch: a dedicated tab per job, reports joined in
    /// dispatch order. Each child acts in its OWN tab's webview so they
    /// never click each other's pages; tabs stay open for inspection.
    private func runParallelSubagents(jobs: [(task: String, maxSteps: Int)]) async -> String {
        guard let tabManager = toolProvider.surface?.tabManager else {
            return "Tab manager unavailable — cannot open per-subagent tabs"
        }
        var webviews: [WKWebView?] = []
        var progressIDs: [UUID] = []
        for job in jobs {
            tabManager.addTab(
                url: nil,
                javaScriptEnabled: toolProvider.surface?.settings.isJavaScriptEnabled ?? true,
                contentBlocker: toolProvider.surface?.contentBlocker,
                videoAdBlocker: toolProvider.surface?.videoAdBlocker
            )
            if let tab = tabManager.tabs.last {
                // Background tab: keep its webview live and navigable.
                tab.isOnNewTabPage = false
                tab.isSuspended = false
                webviews.append(tab.browser.webView)
            } else {
                webviews.append(nil)
            }
            let progress = SubagentProgress(label: Self.progressLabel(job.task), maxSteps: job.maxSteps)
            runningSubagents.append(progress)
            progressIDs.append(progress.id)
        }
        defer {
            runningSubagents.removeAll { progressIDs.contains($0.id) }
        }

        let reports = await withTaskGroup(
            of: (index: Int, report: String).self
        ) { group in
            for (i, job) in jobs.enumerated() {
                let webView = webviews[i]
                let progressID = progressIDs[i]
                group.addTask { @MainActor in
                    let report = await self.runSubagentLoop(
                        task: job.task, maxSteps: job.maxSteps,
                        webView: webView, progressID: progressID
                    )
                    return (index: i, report: report)
                }
            }
            var out = [(index: Int, report: String)]()
            for await piece in group { out.append(piece) }
            return out.sorted { $0.index < $1.index }
        }

        return zip(jobs.indices, reports).map { i, piece in
            "[Subagent \(i + 1): \(Self.progressLabel(jobs[i].task))]\n\(piece.report)"
        }.joined(separator: "\n\n---\n\n")
    }

    /// One subagent's model→tools→model loop. Runs on the main actor; all
    /// parallelism comes from interleaving at await points.
    private func runSubagentLoop(
        task: String, maxSteps: Int, webView: WKWebView?, progressID: UUID
    ) async -> String {
        let pageContext = await fetchCompactPageContext()
        let composed = AgentPromptBuilder.compose(.init(
            identity: Self.subagentIdentity,
            memoryBlock: nil,
            skills: SkillStore.shared.skills.map { ($0.name, $0.description) },
            tools: BrowserToolProvider.promptInventory(for: Self.subagentAllowedToolDefs + MCPStore.shared.toolDefs),
            workspacePath: SystemCommandStore.shared.workingDirectory.path,
            downloadsPath: AgentPromptBuilder.downloadsPath,
            ffmpegAvailable: FFmpegExporter.isAvailable,
            ffmpegPath: FFmpegExporter.locate()?.path,
            pageContext: pageContext
        ))
        var subMessages: [AgentMessage] = [
            AgentMessage(role: .system, content: composed),
            AgentMessage(role: .user, content: task),
        ]

        let outerAction = currentAction
        defer { currentAction = outerAction }

        func reportProgress(step: Int, tool: String?) {
            guard let idx = runningSubagents.firstIndex(where: { $0.id == progressID }) else { return }
            runningSubagents[idx].step = step
            runningSubagents[idx].currentTool = tool
        }

        for step in 1...maxSteps {
            if isCancelled { return "[Cancelled]" }
            await waitWhilePaused()
            reportProgress(step: step, tool: nil)

            var assistant = AgentMessage(role: .assistant, content: "")
            do {
                let active = makeActiveProvider()
                // No recursion: the subagent cannot spawn subagents.
                let stream = active.provider.stream(
                    messages: subMessages,
                    tools: Self.subagentAllowedToolDefs + MCPStore.shared.toolDefs,
                    prefs: preference
                )
                for try await event in stream {
                    if isCancelled { return "[Cancelled]" }
                    switch event {
                    case .text(let delta):
                        assistant.content = (assistant.content ?? "") + delta
                    case .toolCall(let call):
                        assistant.toolCalls = (assistant.toolCalls ?? []) + [call]
                    case .reasoning(let delta):
                        // 子代理也收思考过程：跟正文一起进它那条消息（面板里可折叠）。
                        assistant.reasoning = (assistant.reasoning ?? "") + delta
                    case .usage:
                        break
                    }
                }
            } catch {
                return "Subagent stream failed: \(error.localizedDescription)"
            }
            subMessages.append(assistant)

            guard let tcs = assistant.toolCalls, !tcs.isEmpty else {
                let report = (assistant.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return report.isEmpty ? "Subagent finished without a report." : String(report.prefix(4000))
            }

            for tc in tcs {
                if isCancelled { return "[Cancelled]" }
                await waitWhilePaused()
                reportProgress(step: step, tool: tc.function.name)
                let decision = await gate(toolCall: tc, risk: ToolRisk.classify(tc.function.name))
                switch decision {
                case .denied:
                    subMessages.append(AgentMessage(
                        role: .tool,
                        content: "[User denied this action.]",
                        toolCallId: tc.id,
                        toolName: tc.function.name
                    ))
                    continue
                case .allowedOnce, .allowedAlways:
                    break
                }
                currentAction = "subagent · \(tc.function.name)"
                let target = webView ?? activeWebView ?? WKWebView()
                let result = await toolProvider.execute(tc, in: target)
                subMessages.append(AgentMessage(
                    role: .tool,
                    content: String(result.prefix(8000)),
                    toolCallId: tc.id,
                    toolName: tc.function.name
                ))
            }
            reportProgress(step: step, tool: nil)
            currentAction = outerAction
        }

        let partial = subMessages.last(where: { $0.role == .assistant })?.content ?? ""
        return "Subagent hit its step cap (\(maxSteps)). Partial result: \(partial.prefix(600))"
    }

    private static func progressLabel(_ task: String) -> String {
        let flat = task.replacingOccurrences(of: "\n", with: " ")
        return String(flat.prefix(36)) + (flat.count > 36 ? "…" : "")
    }

    private static let subagentIdentity = """
    You are a focused SUB-AGENT executing one delegated task autonomously. \
    You have the same browser/file/command tools as the main agent, but the \
    user sees only your FINAL message — make it the complete report. Rules:
    - Work only on the delegated task.
    - You run in your own dedicated tab; tab/window management, app-wide \
    toggles, and recording tools are unavailable.
    - You cannot ask the user questions; make reasonable assumptions and note them.
    - When done, reply with the final report (facts found, actions taken, \
    file paths written, anything the main agent must know). Do not call more \
    tools once the report is ready.
    """

    /// Replaces the truncated-first-message title with a proper generated
    /// one, once per conversation.
    // MARK: - 自评（Reflection）

    /// 把"最近一轮"（最后一条 user 消息之后）整理成自评用的紧凑轨迹。
    /// 从已有消息派生，不在热路径上额外记账。
    private func currentTurnTrace() -> (goal: String, trace: String, toolCount: Int, dangerous: Bool) {
        guard let start = messages.lastIndex(where: { $0.role == .user }) else {
            return ("", "", 0, false)
        }
        let goal = messages[start].content ?? ""
        var lines: [String] = []
        var toolCount = 0
        var dangerous = false
        for message in messages[start...] {
            switch message.role {
            case .assistant:
                for call in message.toolCalls ?? [] {
                    toolCount += 1
                    if ToolRisk.classify(call.function.name) == .dangerous { dangerous = true }
                    lines.append("▶ \(call.function.name)(\(call.function.arguments.prefix(160)))")
                }
                if let text = message.content, !text.isEmpty {
                    lines.append("答: \(text.prefix(400))")
                }
            case .tool:
                lines.append("◀ \(message.toolName ?? "result"): \((message.content ?? "").prefix(240))")
            default:
                break
            }
        }
        return (goal, lines.joined(separator: "\n"), toolCount, dangerous)
    }

    /// 一次自评调用：**同一个模型、不带工具、只看轨迹**。失败或取消返回 nil
    /// （自评永远不能把一轮正常回合变成失败）。
    func runCritique(goal: String, trace: String) async -> String? {
        guard !goal.isEmpty, !trace.isEmpty else { return nil }
        let request: [AgentMessage] = [
            AgentMessage(role: .system, content: Self.critiquePrompt),
            AgentMessage(role: .user, content: "目标：\n\(goal)\n\n执行轨迹：\n\(trace)"),
        ]
        var text = ""
        do {
            let active = makeActiveProvider()
            for try await event in active.provider.stream(messages: request, tools: [], prefs: preference) {
                if isCancelled { return nil }
                if case .text(let delta) = event { text += delta }
            }
        } catch {
            Log.agent.info("self-review call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 工具 `reflect` 的入口：模型按需回头审一遍这一轮，评语**返回给它自己**
    /// （它可据此修正答案或补验证）。
    func reflectForTool(question: String) async -> String {
        let turn = currentTurnTrace()
        guard !turn.trace.isEmpty else { return "Nothing to review yet — no actions taken in this turn." }
        let goal = question.isEmpty ? turn.goal : "\(turn.goal)\n（额外关注：\(question)）"
        guard let critique = await runCritique(goal: goal, trace: turn.trace) else {
            return "Self-review unavailable (the model returned nothing)."
        }
        return critique
    }

    /// 工具返回"看起来不像成功"的保守判据（用于软提示）。只认几种最典型的前缀；
    /// 命中只影响一句措辞保守的提示，不会阻止任何事。
    private static func looksLikeToolFailure(_ text: String) -> Bool {
        for prefix in ["Missing", "Not found", "No such", "Failed", "Unknown", "Invalid",
                       "Cannot", "Could not", "Unable", "Unsupported", "No "] where text.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// 用户对某条回答的评价（面板里 👍/👎）。传 nil 清除。按 id 定位，落盘。
    /// 返回**是否命中当前会话**——调用方（桥端点）据此决定要不要去改已存盘的会话，
    /// 免得对已关闭的会话投票时静默无效却报成功。
    @discardableResult
    func setFeedback(_ vote: String?, for messageID: UUID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        let normalized = (vote == "up" || vote == "down") ? vote : nil
        guard messages[index].feedback != normalized else { return true }
        messages[index].feedback = normalized
        streamingVersion += 1
        saveCurrentConversation()
        return true
    }

    /// 回合收尾的**机械核验**：0 次模型调用，只看客观事实——专门抓"连自评都可能漏掉"
    /// 的情况。当前两条：
    /// ① 本轮**所有**工具调用都失败/被拒，却给出了最终回答（结论背后没有验证）；
    /// ② 同一个工具用**相同参数**失败 ≥2 次（在绕路，提示"换策略"）。
    /// 结果写成给**用户**看的橙色提示，不阻塞、不重试、不回传给模型。
    private func runMechanicalVerification() {
        guard let start = messages.lastIndex(where: { $0.role == .user }) else { return }
        // 失败判定只认应用自己写的两个标记：拒绝执行 [User denied…] 与 JS 异常 Error:。
        // 其它工具失败都是普通文本、没有统一约定，靠关键词猜会误报，而全部失败这种
        // 结论必须可证、不能猜。
        var totalCalls = 0
        var markedFailures = 0
        var successfulLooking = 0
        var failedSignatures: [String: Int] = [:]
        var lastCallSignature: String?
        for message in messages[start...] {
            switch message.role {
            case .assistant:
                for call in message.toolCalls ?? [] {
                    totalCalls += 1
                    lastCallSignature = "\(call.function.name)|\(call.function.arguments)"
                }
            case .tool:
                let text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("Error:") || text.hasPrefix("[User denied") {
                    markedFailures += 1
                    if let signature = lastCallSignature { failedSignatures[signature, default: 0] += 1 }
                } else if !text.isEmpty, !Self.looksLikeToolFailure(text) {
                    successfulLooking += 1
                }
            default:
                break
            }
        }
        var notes: [String] = []
        // 软提示：没有任何一条结果**看起来**是成功的。措辞刻意保守（"看不出成功"），
        // 因为普通工具失败没有统一约定，这里不冒充确证——但"全都没成功却给了结论"
        // 值得让用户瞥一眼。
        if totalCalls > 0, markedFailures < totalCalls, successfulLooking == 0 {
            notes.append(String(localized: "None of this turn's tool calls returned anything that looks like success — treat the reply above as unverified."))
        }
        if totalCalls > 0, markedFailures == totalCalls {
            notes.append(String(localized: "Every tool call in this turn was denied or errored — the reply above rests on nothing that actually ran."))
        }
        let repeated = failedSignatures.values.filter { $0 >= 2 }.count
        if repeated > 0 {
            notes.append(String(localized: "The same call was denied or errored twice with identical arguments — repeating it rarely helps; a different approach does."))
        }
        guard !notes.isEmpty,
              let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[index].verificationNote = notes.joined(separator: "\n")
        streamingVersion += 1
        saveCurrentConversation()
    }

    /// 回合收尾的**自动**自评：只在"≥3 次工具调用或含高风险动作"的回合跑——普通闲聊
    /// 不打扰、也不多花一次模型调用。结果折叠挂在最后一条助手消息上。
    private func runSelfReviewIfNeeded() async {
        guard preference.selfReviewEnabled else { return }
        let turn = currentTurnTrace()
        guard turn.toolCount >= 3 || turn.dangerous else { return }
        guard let critique = await runCritique(goal: turn.goal, trace: turn.trace) else { return }
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[index].critique = critique
        streamingVersion += 1
        saveCurrentConversation()
    }

    private func generateTitleIfNeeded() async {
        guard !titleGenerated, messages.count >= 2,
              messages.contains(where: { $0.role == .user }) else { return }
        titleGenerated = true
        guard let title = await MemoryExtractor.generateTitle(
            preference: preference, messages: Array(messages.prefix(6))
        ) else { return }
        conversationTitle = title
        saveCurrentConversation()
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
    private func gate(toolCall: AgentToolCall, risk: ToolRisk) async -> ApprovalOutcome {
        if isCancelled { return .denied }

        // One approval prompt at a time — parallel subagents queue here.
        await acquireApprovalSlot()
        defer { approvalSlotBusy = false }

        // FULL ACCESS: the user explicitly delegated every tool decision —
        // including dangerous-tier executeJS — so nothing pauses.
        if fullAccess { return .allowedOnce }

        // Safe tools always run.
        if risk == .readonly { return .allowedOnce }

        // Whitelisted side-effect tools run without prompting. Dangerous
        // tools are exempt from the whitelist and always prompt.
        if risk != .dangerous && preference.allowedTools.contains(toolCall.function.name) {
            ApprovalPolicyStore.shared.recordHistory(
                toolName: toolCall.function.name, decision: "allowed (whitelist)", source: "whitelist")
            return .allowedOnce
        }

        // 审批策略引擎（0.2.6）：持久化规则优先于内置白名单。deny 规则
        // 对 dangerous 工具也生效（显式拒绝优先于一切）。
        if let policy = ApprovalPolicyStore.shared.decision(for: toolCall.function.name) {
            switch policy {
            case .deny:
                ApprovalPolicyStore.shared.recordHistory(
                    toolName: toolCall.function.name, decision: "denied (policy)", source: "policy")
                return .denied
            case .allow:
                ApprovalPolicyStore.shared.recordHistory(
                    toolName: toolCall.function.name, decision: "allowed (policy)", source: "policy")
                return .allowedOnce
            }
        }

        // Everything else pauses for the user.
        return await requestApproval(toolCall: toolCall, risk: risk)
    }

    /// Suspends the loop until the user resolves the pending approval.
    /// The continuation is resumed by `resolveApproval(_:)`.
    private func requestApproval(toolCall: AgentToolCall, risk: ToolRisk) async -> ApprovalOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalOutcome, Never>) in
            pendingApproval = PendingToolApproval(
                toolCall: toolCall,
                risk: risk,
                argumentsSummary: summarizeArguments(toolCall),
                continuation: continuation
            )
            BridgeEventBus.shared.publish("approvalPending", [
                "tool": toolCall.function.name,
                "risk": risk.displayName,
            ])
        }
    }

    /// Called by the UI (`ToolApprovalBar`) when the user decides.
    func resolveApproval(_ decision: ApprovalDecision) {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil
        ApprovalPolicyStore.shared.recordHistory(
            toolName: approval.toolCall.function.name,
            decision: decision == .deny ? "denied" : "allowed",
            source: "ui")

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

    /// Automation-bridge hook: arms a REAL pending approval (a live
    /// continuation that `resolveApproval` resumes) without running a model
    /// turn. Only reachable via the automation server, which exists solely
    /// under `--automation`. Lets external drivers exercise the approve/deny
    /// plumbing — sheet state, decision routing, continuation resumption —
    /// deterministically.
    func simulateApprovalForTesting() {
        let toolCall = AgentToolCall(
            id: "simulate-\(UUID().uuidString.prefix(8))",
            type: "function",
            function: AgentToolFunction(name: "readClipboard", arguments: "{}")
        )
        Task { [weak self] in
            guard let self else { return }
            Log.agent.info("simulate: gate entered, isCancelled=\(self.isCancelled)")
            let outcome = await self.gate(toolCall: toolCall, risk: .dangerous)
            Log.agent.info("simulate: gate returned \(String(describing: outcome), privacy: .public)")
            Log.agent.info("simulated approval resolved with \(String(describing: outcome), privacy: .public)")
        }
    }

    /// Produces a short human-readable summary of a tool call's arguments
    /// for display in the approval bar. Falls back to the raw JSON if
    /// parsing fails.
    private func summarizeArguments(_ call: AgentToolCall) -> String {
        guard let data = call.function.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !dict.isEmpty else {
            return call.function.arguments.isEmpty ? "(no arguments)" : call.function.arguments
        }
        // A system command is safest judged as the exact command line.
        if call.function.name == "runCommand", let tool = dict["tool"] as? String {
            let argv = (dict["args"] as? [String]) ?? []
            var line = ([tool] + argv).joined(separator: " ")
            if let timeout = dict["timeoutSec"] { line += "  (timeout: \(timeout)s)" }
            return line.count > 240 ? String(line.prefix(240)) + "…" : line
        }
        // Surface the primary intent field first for common tools.
        for key in ["url", "text", "content", "value", "name"] {
            if let value = dict[key] as? String {
                return key + ": " + (value.count > 80 ? String(value.prefix(80)) + "…" : value)
            }
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

    /// A pending tool-call approval. Published by `AgentSessionStore` so the UI
/// can render a prompt; the embedded continuation resumes the loop when
/// the user decides (or when the conversation is cancelled).
///
/// `@MainActor` because it's only ever constructed, observed, and resumed
/// on the main actor (the store is `@MainActor`).
@MainActor
final class PendingToolApproval: Identifiable {
    let id = UUID()
    let toolCall: AgentToolCall
    let risk: ToolRisk
    let argumentsSummary: String
    private var continuation: CheckedContinuation<ApprovalOutcome, Never>?

    init(toolCall: AgentToolCall, risk: ToolRisk, argumentsSummary: String,
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
