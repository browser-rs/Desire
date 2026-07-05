import Combine
import WebKit

@MainActor
class AISessionStore: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var isProcessing = false
    @Published var currentAction: String?

    var preference = AIPreferenceStore()
    private let toolProvider = BrowserToolProvider()
    private weak var webView: WKWebView?
    private var isCancelled = false

    func setWebView(_ wv: WKWebView?) {
        webView = wv
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(AIMessage(role: .user, content: trimmed))
        isProcessing = true
        isCancelled = false
        Task { await processLoop() }
    }

    func addContext(html: String, selector: String) {
        let context = "<\(selector)>: \(html.prefix(1000))"
        messages.append(AIMessage(role: .user, content: "[Selected element]\n\(context)"))
    }

    func cancel() {
        isCancelled = true
        isProcessing = false
        currentAction = nil
    }

    func clear() {
        messages.removeAll()
        isProcessing = false
        currentAction = nil
        isCancelled = false
    }

    private func processLoop() async {
        defer {
            isProcessing = false
            currentAction = nil
        }

        for _ in 0..<20 {
            if isCancelled { return }

            let hasTools = !messages.contains { $0.role == .tool }
            let stream = AIService.stream(
                messages: messages,
                tools: hasTools ? BrowserToolProvider.toolDefs : [],
                prefs: preference
            )

            var assistantMsg = AIMessage(role: .assistant, content: "")
            messages.append(assistantMsg)

            do {
                for try await event in stream {
                    if isCancelled { return }
                    switch event {
                    case .text(let delta):
                        assistantMsg.content = (assistantMsg.content ?? "") + delta
                        if let idx = messages.lastIndex(where: { $0.id == assistantMsg.id }) {
                            messages[idx] = assistantMsg
                        }
                    case .toolCall(let call):
                        assistantMsg.toolCalls = (assistantMsg.toolCalls ?? []) + [call]
                        if let idx = messages.lastIndex(where: { $0.id == assistantMsg.id }) {
                            messages[idx] = assistantMsg
                        }
                    }
                }
            } catch {
                messages.append(AIMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
                return
            }

            if let idx = messages.firstIndex(where: { $0.id == assistantMsg.id }) {
                messages[idx] = assistantMsg
            }

            guard let tcs = assistantMsg.toolCalls, !tcs.isEmpty else { return }

            for tc in tcs {
                if isCancelled { return }
                currentAction = tc.function.name
                let result = await toolProvider.execute(tc, in: webView ?? WKWebView())
                messages.append(AIMessage(role: .tool, content: result, toolCallId: tc.id))
            }
            currentAction = nil
        }
    }
}
