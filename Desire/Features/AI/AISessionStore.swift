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

    var preference = AIPreferenceStore()
    private let toolProvider = BrowserToolProvider()
    private weak var webView: WKWebView?
    private var isCancelled = false
    weak var conversationStore: ConversationStore?

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

        for _ in 0..<20 {
            if isCancelled { return }

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

            for tc in tcs {
                if isCancelled { return }
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
        }
    }
}
