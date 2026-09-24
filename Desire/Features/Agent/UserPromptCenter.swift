import Combine
import Foundation

/// Mid-task user clarification channel: the agent's `askUser` tool pauses
/// the loop until the user answers in the panel. Mirrors the
/// PendingToolApproval continuation pattern.
@MainActor
final class UserPromptCenter: ObservableObject {
    static let shared = UserPromptCenter()

    /// 提问的兜底超时（秒）：定时/后台回合的提问在面板没开时用户**根本看不见**，
    /// 没有超时回合就无限挂起。默认 10 分钟；超过即以标记解除，回合继续走。
    static let answerTimeout: TimeInterval = {
        let v = UserDefaults.standard.object(forKey: "agentAskUserTimeout") as? Double
        return v ?? 600
    }()

    @Published private(set) var pending: PendingUserQuestion?

    /// Suspends the calling tool until the user answers (or cancels — the
    /// answer is then a marker string the agent can understand). 超过
    /// `answerTimeout` 无人回答则自动以超时标记解除（见 PendingUserQuestion）。
    func ask(_ question: String) async -> String {
        await withCheckedContinuation { continuation in
            let entry = PendingUserQuestion(question: question, continuation: continuation)
            pending = entry
            entry.scheduleTimeout(after: Self.answerTimeout)
        }
    }

    func answer(_ text: String) {
        pending?.resume(with: text)
        pending = nil
    }

    /// Session cancelled — unblock the tool with a cancellation marker.
    func cancel() {
        pending?.resume(with: "[user cancelled — no answer]")
        pending = nil
    }
}

@MainActor
final class PendingUserQuestion: Identifiable {
    let id = UUID()
    let question: String
    private var continuation: CheckedContinuation<String, Never>?
    fileprivate var timeoutTask: Task<Void, Never>?

    init(question: String, continuation: CheckedContinuation<String, Never>) {
        self.question = question
        self.continuation = continuation
    }

    /// 兜底超时：长时间无人回答就以标记解除挂起（回合不至于无限等）。
    fileprivate func scheduleTimeout(after seconds: TimeInterval) {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.resume(with: "[no answer — the user did not respond in time]")
        }
    }

    /// **只恢复一次**：回答、取消、超时三方都可能到达，续两次会崩溃。
    func resume(with answer: String) {
        guard continuation != nil else { return }
        timeoutTask?.cancel()
        continuation?.resume(returning: answer)
        continuation = nil
    }
}
