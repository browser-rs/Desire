import Combine
import Foundation

/// A multi-step task checklist the agent maintains via the `updatePlan`
/// tool — the user sees live progress (pending / in-progress / done) in the
/// panel, the way modern coding agents render their todo lists.
struct AgentPlanStep: Identifiable {
    let id = UUID()
    let content: String
    /// pending | in_progress | done
    let status: String
}

@MainActor
final class AgentPlanStore: ObservableObject {
    static let shared = AgentPlanStore()

    @Published private(set) var steps: [AgentPlanStep] = []
    @Published private(set) var lastUpdated = Date()

    func set(_ steps: [AgentPlanStep]) {
        self.steps = steps
        lastUpdated = Date()
    }

    func clear() {
        steps = []
    }
}
