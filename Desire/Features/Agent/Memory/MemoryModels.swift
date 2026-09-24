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
    /// "global" or a host ("github.com") — domain-scoped facts only inject
    /// when the agent's current page matches that host.
    var scope: String = "global"

    init(content: String, category: String, pinned: Bool = false, scope: String = "global") {
        self.id = UUID()
        self.content = content
        self.category = category
        self.createdAt = Date()
        self.updatedAt = Date()
        self.pinned = pinned
        self.scope = scope
    }
}

/// L2 — per-conversation summary so past sessions can inform future ones
/// without loading their raw transcripts (L3, already in ConversationStore).
enum MemoryModels {
    /// 记忆事实的**归一化**：小写、去空白与常见标点 —— 近似重复判定用它。
    static func normalizeFact(_ text: String) -> String {
        let lowered = text.lowercased()
        let skipped = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "，。、！？：；\"'()（）[]【】…—,.!?;:"))
        return String(lowered.unicodeScalars.filter { !skipped.contains($0) })
    }

    /// 近似重复判定：字符 bigram 的 Jaccard 相似度 ≥ 0.8 视为重复。
    /// （注释曾写"近似重复"而实现只做精确匹配 —— 语义重复会堆积，
    /// 把 200 条上限挤满。没有端上 embedding，字符 bigram 是够用的下限。）
    static func areNearDuplicates(_ a: String, _ b: String) -> Bool {
        func bigrams(_ t: String) -> Set<String> {
            let chars = Array(t)
            guard chars.count > 1 else { return [t] }
            return Set((0...(chars.count - 2)).map { String(chars[$0...$0 + 1]) })
        }
        let x = bigrams(a), y = bigrams(b)
        if x.isEmpty || y.isEmpty { return a == b }
        let inter = x.intersection(y).count
        let union = x.union(y).count
        return Double(inter) / Double(union) >= 0.8
    }
}

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
