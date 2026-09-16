import Combine
import Foundation

/// Mid-task user clarification channel: the agent's `askUser` tool pauses
/// the loop until the user answers in the panel. Mirrors the
/// PendingToolApproval continuation pattern.
@MainActor
final class UserPromptCenter: ObservableObject {
    static let shared = UserPromptCenter()

    @Published private(set) var pending: PendingUserQuestion?

    /// Suspends the calling tool until the user answers (or cancels — the
    /// answer is then a marker string the agent can understand).
    func ask(_ question: String) async -> String {
        await withCheckedContinuation { continuation in
            pending = PendingUserQuestion(question: question, continuation: continuation)
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

    init(question: String, continuation: CheckedContinuation<String, Never>) {
        self.question = question
        self.continuation = continuation
    }

    func resume(with answer: String) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}
