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
    func ask(_ question: String, quickOptions: [String]? = nil) async -> String {
        await withCheckedContinuation { continuation in
            // P1-19：并行批（askUser 归 readonly 可并发）第二问会覆盖第一问
            // 的 pending——旧续体只能等 600s 超时。先以标记解除旧问，保证
            // 面板永远只显示一张卡且旧循环立刻醒来。
            if let stale = pending {
                stale.resume(with: "[superseded by a newer question]")
            }
            let entry = PendingUserQuestion(
                question: question, continuation: continuation,
                quickOptions: quickOptions)
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
    /// 快捷按钮（如 允许/拒绝）——nil = 纯文本问答。
    let quickOptions: [String]?
    private var continuation: CheckedContinuation<String, Never>?
    fileprivate var timeoutTask: Task<Void, Never>?

    init(
        question: String, continuation: CheckedContinuation<String, Never>,
        quickOptions: [String]? = nil
    ) {
        self.question = question
        self.continuation = continuation
        self.quickOptions = quickOptions
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
