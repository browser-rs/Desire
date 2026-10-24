import Combine
import Foundation

/// 阅读模式 AI 摘要（v0.8.6）：旁路流式调用（不占 Agent 回合、不产生会话
/// 消息），复用划词就地卡的旁路档案与流管道。结果只存在于本卡模型里，
/// 关闭阅读视图即弃。
@MainActor
final class ReaderSummaryModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case streaming
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var text = ""

    private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .streaming }

    /// 摘要/要点二选一；`kind` 决定系统提示词。正文超长时截前 24k 字符
    /// （旁路调用无上下文压缩管道，超限直接报错更糟）。
    func run(articleText: String, kind: Kind) {
        let trimmed = articleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed(String(localized: "No article text"))
            return
        }
        task?.cancel()
        text = ""
        phase = .streaming
        let body = String(trimmed.prefix(24_000))
        task = Task { @MainActor in
            do {
                let result = try await SelectionAssistService.stream(
                    text: body,
                    systemPrompt: kind.systemPrompt,
                    userPrompt: body,
                    onDelta: { [weak self] partial in
                        guard let self, !Task.isCancelled else { return }
                        self.text = partial
                    })
                guard !Task.isCancelled else { return }
                text = result
                phase = .done
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        task?.cancel()
        phase = .idle
        text = ""
    }

    enum Kind: String, CaseIterable, Identifiable {
        case summary
        case keyPoints
        var id: String { rawValue }

        var systemPrompt: String {
            switch self {
            case .summary:
                return "You are a reading assistant. Summarize the article in the SAME language as the article. Write 2-4 concise paragraphs. Do not invent facts, do not use headers or bullet lists."
            case .keyPoints:
                return "You are a reading assistant. Extract the key points of the article in the SAME language as the article. Output 3-8 bullet lines, each starting with '- ', each a single sentence. Do not invent facts."
            }
        }

        var buttonLabel: String {
            switch self {
            case .summary: String(localized: "Summarize")
            case .keyPoints: String(localized: "Key Points")
            }
        }
    }
}
