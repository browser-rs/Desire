import Combine
import Foundation
import os

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

    /// 云同步待删清单（tombstone）：事实与摘要共用（id 空间不重叠），
    /// 模式同 BookmarkStore.pendingDeletions。
    @Published private(set) var pendingDeletions: [String: Date] = [:]
    private static let deletionsKey = "agent-memory.deletions"

    private init() {
        var loaded = DiskStore.load(MemoryArchive.self, key: Self.key) ?? MemoryArchive()
        if loaded.profileUpdatedAt == nil { loaded.profileUpdatedAt = Date() }
        for i in loaded.facts.indices where loaded.facts[i].updatedAt == .distantPast {
            loaded.facts[i].updatedAt = Date()
        }
        archive = loaded
        pendingDeletions = DiskStore.load([String: Date].self, key: Self.deletionsKey) ?? [:]
    }

    /// Convenience for view branching (onboarding shows until completed).
    var onboardingCompleted: Bool { archive.onboardingCompleted }

    private func save() {
        DiskStore.save(archive, key: Self.key)
    }

    // MARK: - 云同步（SyncStore 驱动）

    /// 同步合并结果整体替换（LWW 仲裁已在合并层完成）。
    func replaceForSync(_ replaced: MemoryArchive) {
        archive = replaced
        save()
    }

    /// push 成功后从待删清单移除（serverIDs = HMAC 形态的服务端条目 id）。
    func clearPendingDeletions(_ serverIDs: Set<String>, hmacOf realID: (String) -> String) {
        let hits = pendingDeletions.keys.filter { serverIDs.contains(realID($0)) }
        guard !hits.isEmpty else { return }
        for id in hits { pendingDeletions.removeValue(forKey: id) }
        DiskStore.save(pendingDeletions, key: Self.deletionsKey)
    }

    private func recordDeletion(_ id: String) {
        pendingDeletions[id] = Date()
        DiskStore.save(pendingDeletions, key: Self.deletionsKey)
    }

    // MARK: - Profile & onboarding

    func updateProfile(_ mutate: (inout UserProfile) -> Void) {
        mutate(&archive.profile)
        archive.profileUpdatedAt = Date()
        save()
    }

    func completeOnboarding() {
        archive.onboardingCompleted = true
        save()
    }

    // MARK: - Facts (L1)

    /// Adds a fact, skipping near-duplicates of what's already known.
    /// Newest first, hard cap keeps the archive (and prompt block) bounded.
    /// 删除内容包含指定子串的事实（按前缀 supersede 用），并记录删除墓碑
    /// （同步到其它设备）。
    func removeFacts(containing substring: String) {
        let doomed = archive.facts.filter { $0.content.contains(substring) }
        guard !doomed.isEmpty else { return }
        for fact in doomed { recordDeletion(fact.id.uuidString) }
        archive.facts.removeAll { fact in doomed.contains(where: { $0.id == fact.id }) }
        save()
    }

    func addFact(content: String, category: String, scope: String = "global", source: String? = nil) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return }
        // 近似重复（归一化 + bigram 相似度）：注释口径与实现此前不符（只做精确匹配），
        // 语义重复会堆积。已 pin 的事实同样参与去重，不会被绕过。
        let normalized = MemoryModels.normalizeFact(trimmed)
        if archive.facts.contains(where: { MemoryModels.areNearDuplicates(MemoryModels.normalizeFact($0.content), normalized) }) { return }
        archive.facts.insert(MemoryFact(content: trimmed, category: category, scope: scope, source: source), at: 0)
        archive.factsTotalLearned += 1
        if archive.facts.count > 200 {
            // Drop unpinned oldest first.
            if let oldest = archive.facts.lastIndex(where: { !$0.pinned }) {
                recordDeletion(archive.facts[oldest].id.uuidString)
                archive.facts.remove(at: oldest)
            } else {
                recordDeletion(archive.facts.last!.id.uuidString)
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
        archive.facts[idx].updatedAt = Date()
        save()
    }

    func removeFact(_ id: UUID) {
        archive.facts.removeAll { $0.id == id }
        recordDeletion(id.uuidString)
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
        recordDeletion(id.uuidString)
        save()
    }

    /// Clears ALL learned memory (L1 facts + L2 summaries) in one step.
    /// The L0 profile survives — it's the user's self-description, not
    /// something the agent inferred.
    func clearLearnedMemory() {
        let now = Date()
        for fact in archive.facts { pendingDeletions[fact.id.uuidString] = now }
        for summary in archive.summaries { pendingDeletions[summary.id.uuidString] = now }
        archive.facts.removeAll()
        archive.summaries.removeAll()
        DiskStore.save(pendingDeletions, key: Self.deletionsKey)
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

    /// 记忆知识库 Markdown（ReMe 式可读导出：画像/分组事实/相关互链/摘要）。
    /// 桥 `GET /memory/export?format=markdown` 与记忆面板导出按钮同源。
    func markdownKB() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let facts = archive.facts.map {
            MemoryKB.FactInput(content: $0.content, category: $0.category,
                               scope: $0.scope, source: $0.source,
                               pinned: $0.pinned,
                               updatedText: formatter.string(from: $0.updatedAt))
        }
        let summaries = archive.summaries.map { summary -> MemoryKB.SummaryInput in
            let title = AppState.live?.conversationStore
                .conversation(for: summary.conversationId)?.title
                ?? "会话 \(summary.conversationId.uuidString.prefix(8))"
            return MemoryKB.SummaryInput(title: title, text: summary.summary,
                                         updatedText: formatter.string(from: summary.createdAt))
        }
        let profile = archive.profile
        return MemoryKB.render(
            profile: ["名字": profile.name, "语言": profile.language,
                      "语气": profile.style, "自定义指令": profile.customInstructions],
            facts: facts, summaries: summaries,
            generatedText: formatter.string(from: Date()))
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
    /// - Parameters:
    ///   - query: 当前对话的检索查询（最近几条 user 消息拼接）。检索 = 向量
    ///     主排（BGEEmbedder 在场时）+ BM25 降级；nil/空 = 最近优先兜底。
    func promptBlock(excluding currentConversation: UUID?, currentHost: String? = nil,
                     query: String? = nil) async -> String? {
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
        // 注入量 = pinned 恒定 + 相关性 top-K（全量注入曾到 200 条，
        // 爆上下文且稀释注意力）。
        let loweredHost = (currentHost ?? "").lowercased()
        let scoped = archive.facts
            .filter { fact in
                let scope = fact.scope.lowercased()
                return scope.isEmpty || scope == "global"
                    || loweredHost.contains(scope)
                    || scope.hasSuffix("." + loweredHost)
            }
        let facts = await retrieveRanked(scoped: scoped, query: query ?? "")
        Log.agent.info("memory rank: query='\((query ?? "").prefix(60), privacy: .public)' scoped=\(scoped.count, privacy: .public) selected=\(facts.count, privacy: .public) via=\(BGEEmbedder.isAvailable ? "vector" : "bm25", privacy: .public) first='\(facts.first(where: { !$0.pinned })?.content.prefix(40) ?? "-", privacy: .public)'")
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

    /// 向量主排 + BM25 降级。事实向量按 (id, content hash) 缓存在内存
    /// （进程内 800KB 上限 @200 条 × 512 维；hashValue 每次启动随机化——
    /// 缓存本来就只活一轮，无跨启动语义）。
    private var vectorCache: [UUID: (contentHash: Int, vector: [Double])] = [:]

    private func retrieveRanked(scoped: [MemoryFact], query: String) async -> [MemoryFact] {
        guard BGEEmbedder.isAvailable else {
            return MemoryRetrieval.rank(facts: scoped, query: query)
        }
        // 查询与事实两路嵌入并行；推理在后台，主 actor 只做缓存查改。
        let queryTask = Task.detached(priority: .userInitiated) {
            BGEEmbedder.embedQuery(query)
        }
        var vectors: [UUID: [Double]] = [:]
        var missing: [MemoryFact] = []
        for fact in scoped {
            if let cached = vectorCache[fact.id], cached.contentHash == fact.content.hashValue {
                vectors[fact.id] = cached.vector
            } else {
                missing.append(fact)
            }
        }
        if !missing.isEmpty {
            let computed = await Task.detached(priority: .utility) { () -> [(UUID, Int, [Double])] in
                missing.compactMap { fact in
                    BGEEmbedder.embedFact(fact.content).map { (fact.id, fact.content.hashValue, $0) }
                }
            }.value
            for (id, hash, vector) in computed {
                vectors[id] = vector
                vectorCache[id] = (hash, vector)
            }
        }
        let queryVector = await queryTask.value
        return MemoryRetrieval.rankWithVectors(facts: scoped, query: query,
                                               queryVector: queryVector, vectorsByFactID: vectors)
    }
}
