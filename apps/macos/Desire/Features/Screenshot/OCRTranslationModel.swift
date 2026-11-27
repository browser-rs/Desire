import Combine
import Foundation

/// 截图 OCR 结果的翻译（v0.8.80）：**旁路档案**一次流式调用，不占 Agent 回合、
/// 不写会话。与划词就地卡/阅读摘要共用同一条 SelectionAssistService 管道。
@MainActor
final class OCRTranslationModel: ObservableObject {
    @Published private(set) var translation = ""
    @Published private(set) var isTranslating = false
    @Published private(set) var errorText: String?

    private var task: Task<Void, Never>?

    func translate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTranslating else { return }
        isTranslating = true
        translation = ""
        errorText = nil
        task?.cancel()
        task = Task { [weak self] in
            do {
                let result = try await SelectionAssistService.stream(
                    text: trimmed,
                    systemPrompt: "You are a precise translator. Translate the user's text into the language they are most likely reading (Chinese if the text is not Chinese, English otherwise). Keep names, numbers, code and formatting. Output only the translation.",
                    userPrompt: trimmed,
                    onDelta: { [weak self] partial in
                        self?.translation = partial
                    })
                self?.translation = result
                self?.isTranslating = false
            } catch is CancellationError {
                self?.isTranslating = false
            } catch {
                self?.errorText = error.localizedDescription
                self?.isTranslating = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isTranslating = false
    }
}
