import Foundation

/// L0 — user profile set at onboarding and refined by the agent over time.
struct UserProfile: Codable, Equatable {
    var name: String = ""
    var language: String = ""
    var style: String = ""
    var customInstructions: String = ""

    var isEmpty: Bool {
        name.isEmpty && language.isEmpty && style.isEmpty && customInstructions.isEmpty
    }
}

/// L1 — a durable fact learned about the user ("常去 B 站", "偏好简洁回复").
/// Survives all conversations; injected into every agent request.
struct MemoryFact: Codable, Identifiable, Equatable {
    let id: UUID
    var content: String
    /// preference | habit | fact | correction (free-form, display only).
    var category: String
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool

    init(content: String, category: String, pinned: Bool = false) {
        self.id = UUID()
        self.content = content
        self.category = category
        self.createdAt = Date()
        self.updatedAt = Date()
        self.pinned = pinned
    }
}

/// L2 — per-conversation summary so past sessions can inform future ones
/// without loading their raw transcripts (L3, already in ConversationStore).
struct ConversationSummary: Codable, Identifiable, Equatable {
    let id: UUID
    let conversationId: UUID
    var summary: String
    var createdAt: Date

    init(conversationId: UUID, summary: String) {
        self.id = UUID()
        self.conversationId = conversationId
        self.summary = summary
        self.createdAt = Date()
    }
}

/// The DiskStore payload for `AgentMemoryStore`. One versioned blob — the
/// memory is small (facts capped, summaries capped) so a single file beats
/// per-entry files.
struct MemoryArchive: Codable {
    var profile = UserProfile()
    var facts: [MemoryFact] = []
    var summaries: [ConversationSummary] = []
    var onboardingCompleted = false
    var factsTotalLearned = 0
}
