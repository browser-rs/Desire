import Combine
import Foundation

/// Layered persistent memory for the agent.
///
/// - L0 `profile`      — who the user is (onboarding + agent refinements)
/// - L1 `facts`        — durable user traits/habits, auto-extracted
/// - L2 `summaries`    — per-conversation digests
/// - L3 raw transcript — `ConversationStore` (not managed here)
///
/// The first three are injected into every agent request as a system block
/// (see `promptBlock`), and each layer is user-inspectable and editable in
/// the memory view — memory must never be a silent black box.
@MainActor
final class AgentMemoryStore: ObservableObject {
    static let shared = AgentMemoryStore()

    private static let key = "agent-memory"

    @Published private(set) var archive: MemoryArchive

    private init() {
        archive = DiskStore.load(MemoryArchive.self, key: Self.key) ?? MemoryArchive()
    }

    /// Convenience for view branching (onboarding shows until completed).
    var onboardingCompleted: Bool { archive.onboardingCompleted }

    private func save() {
        DiskStore.save(archive, key: Self.key)
    }

    // MARK: - Profile & onboarding

    func updateProfile(_ mutate: (inout UserProfile) -> Void) {
        mutate(&archive.profile)
        save()
    }

    func completeOnboarding() {
        archive.onboardingCompleted = true
        save()
    }

    // MARK: - Facts (L1)

    /// Adds a fact, skipping near-duplicates of what's already known.
    /// Newest first, hard cap keeps the archive (and prompt block) bounded.
    func addFact(content: String, category: String, scope: String = "global") {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return }
        // 近似重复（归一化 + bigram 相似度）：注释口径与实现此前不符（只做精确匹配），
        // 语义重复会堆积。已 pin 的事实同样参与去重，不会被绕过。
        let normalized = MemoryModels.normalizeFact(trimmed)
        if archive.facts.contains(where: { MemoryModels.areNearDuplicates(MemoryModels.normalizeFact($0.content), normalized) }) { return }
        archive.facts.insert(MemoryFact(content: trimmed, category: category, scope: scope), at: 0)
        archive.factsTotalLearned += 1
        if archive.facts.count > 200 {
            // Drop unpinned oldest first.
            if let oldest = archive.facts.lastIndex(where: { !$0.pinned }) {
                archive.facts.remove(at: oldest)
            } else {
                archive.facts.removeLast()
            }
        }
        save()
    }

    /// Read accessors for the automation bridge (memory management surface).
    var profileSnapshot: UserProfile { archive.profile }
    var factsSnapshot: [MemoryFact] { archive.facts }
    var summariesCount: Int { archive.summaries.count }

    func updateFactContent(_ id: UUID, content: String) {
        guard let idx = archive.facts.firstIndex(where: { $0.id == id }) else { return }
        archive.facts[idx].content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        archive.facts[idx].updatedAt = Date()
        save()
    }

    func togglePin(_ id: UUID) {
        guard let idx = archive.facts.firstIndex(where: { $0.id == id }) else { return }
        archive.facts[idx].pinned.toggle()
        save()
    }

    func removeFact(_ id: UUID) {
        archive.facts.removeAll { $0.id == id }
        save()
    }

    // MARK: - Summaries (L2)

    func upsertSummary(conversationId: UUID, summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return }
        if let idx = archive.summaries.firstIndex(where: { $0.conversationId == conversationId }) {
            archive.summaries[idx].summary = trimmed
            archive.summaries[idx].createdAt = Date()
        } else {
            archive.summaries.insert(ConversationSummary(conversationId: conversationId, summary: trimmed), at: 0)
            if archive.summaries.count > 60 {
                archive.summaries.removeLast(archive.summaries.count - 60)
            }
        }
        save()
    }

    func removeSummary(_ id: UUID) {
        archive.summaries.removeAll { $0.id == id }
        save()
    }

    /// Clears ALL learned memory (L1 facts + L2 summaries) in one step.
    /// The L0 profile survives — it's the user's self-description, not
    /// something the agent inferred.
    func clearLearnedMemory() {
        archive.facts.removeAll()
        archive.summaries.removeAll()
        save()
    }

    // MARK: - Memory v2 (search, export, import, decay)

    /// Substring search across facts (content + category), pinned first.
    func searchFacts(query: String) -> [MemoryFact] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return archive.facts
            .filter { $0.content.lowercased().contains(q) || $0.category.lowercased().contains(q) }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.updatedAt > b.updatedAt
            }
    }

    /// Serialises all facts + profile to JSON for export/backup.
    func exportJSON() -> String {
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "profile": [
                "name": archive.profile.name, "language": archive.profile.language,
                "style": archive.profile.style,
                "customInstructions": archive.profile.customInstructions,
            ],
            "facts": archive.facts.map { f in
                ["content": f.content, "category": f.category,
                 "pinned": f.pinned, "scope": f.scope,
                 "createdAt": formatter.string(from: f.createdAt)]
            },
            "exportedAt": formatter.string(from: Date()),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Imports facts from a JSON array of {content, category?, scope?}.
    /// Skips duplicates. Returns the count of newly added facts.
    @discardableResult
    func importFacts(fromJSON json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return 0 }
        var added = 0
        for item in items {
            guard let content = item["content"] as? String, !content.isEmpty else { continue }
            let category = item["category"] as? String ?? "fact"
            let scope = item["scope"] as? String ?? "global"
            let before = archive.facts.count
            addFact(content: content, category: category, scope: scope)
            if archive.facts.count > before { added += 1 }
        }
        return added
    }

    /// Memory decay: removes unpinned facts older than `days` that haven't
    /// been updated (low-engagement cleanup). Returns the count removed.
    @discardableResult
    func decayOldFacts(olderThanDays: Int = 90) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date()) ?? Date()
        let stale = archive.facts.filter { !$0.pinned && $0.updatedAt < cutoff }
        for fact in stale { removeFact(fact.id) }
        return stale.count
    }

    // MARK: - Prompt injection

    /// The system block injected into every agent request: profile, top
    /// facts (pinned first), and the most recent other-conversation
    /// summaries. Nil when there's nothing to say.
    func promptBlock(excluding currentConversation: UUID?, currentHost: String? = nil) -> String? {
        var lines: [String] = []

        let profile = archive.profile
        if !profile.isEmpty {
            var parts: [String] = []
            if !profile.name.isEmpty { parts.append("称呼: \(profile.name)") }
            if !profile.language.isEmpty { parts.append("语言: \(profile.language)") }
            if !profile.style.isEmpty { parts.append("回复风格: \(profile.style)") }
            if !profile.customInstructions.isEmpty { parts.append("自定义指令: \(profile.customInstructions)") }
            lines.append("Profile: " + parts.joined(separator: "; "))
        }

        // Domain-scoped facts only inject when the current page matches.
        let loweredHost = (currentHost ?? "").lowercased()
        let facts = archive.facts
            .filter { fact in
                let scope = fact.scope.lowercased()
                return scope.isEmpty || scope == "global"
                    || loweredHost.contains(scope)
                    || scope.hasSuffix("." + loweredHost)
            }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                return a.updatedAt > b.updatedAt
            }
            .prefix(20)
        for fact in facts where !fact.content.isEmpty {
            let scopeTag = (fact.scope.isEmpty || fact.scope.lowercased() == "global") ? "" : " [\(fact.scope)]"
            lines.append("- (\(fact.category))\(scopeTag) \(fact.content)")
        }

        for summary in archive.summaries
            .filter({ $0.conversationId != currentConversation })
            .sorted(by: { $0.createdAt > $1.createdAt })
            .prefix(5) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            lines.append("Earlier conversation (\(formatter.string(from: summary.createdAt))): \(summary.summary)")
        }

        guard !lines.isEmpty else { return nil }
        return "[User memory — apply silently, never recite]\n" + lines.joined(separator: "\n")
    }
}
