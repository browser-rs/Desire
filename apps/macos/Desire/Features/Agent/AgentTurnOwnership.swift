import Foundation

/// Tracks which asynchronous Agent turn is allowed to write back into a
/// session. A new turn invalidates every older task, even if cancellation of
/// that task has not reached its next suspension point yet.
struct AgentTurnOwnership {
    private(set) var activeTurnID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        activeTurnID = id
        return id
    }

    mutating func invalidate() {
        activeTurnID = nil
    }

    func isCurrent(_ id: UUID) -> Bool {
        activeTurnID == id
    }
}
