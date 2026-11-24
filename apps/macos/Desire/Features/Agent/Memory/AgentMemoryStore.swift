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
        if let data = AppPrefs.defaults.data(forKey: Self.pendingConflictsKey),
           let decoded = try? JSONDecoder().decode([PendingConflict].self, from: data) {
            pendingConflicts = decoded
        }
        prunePendingConflicts()
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

    /// **按需记忆检索**（v0.8.72 批 1，工具 recallMemory 的后端）：排序与
    /// promptBlock 同一套（retrieveRanked——向量主排 + BM25 降级，向量缓存
    /// 共享），语义不同——promptBlock 管"自动注入 top-K"（排除本会话来源、
    /// 受预算约束），recall 管"模型确认要查"：不排除本会话来源；指定 scope
    /// 时该站点的事实排前、global 全局事实仍可见。待复核冲突的事实不返回
    /// （与 promptBlock 同口径）。
    func recall(query: String, scope: String? = nil, limit: Int = 8) async -> [MemoryFact] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let normalizedScope = MemoryModels.normalizeScope(scope)
        let pendingIDs = Set(pendingConflicts.map(\.factID))
        var pool = archive.facts.filter { !pendingIDs.contains($0.id) && !$0.content.isEmpty }
        if normalizedScope != "global" {
            let site = pool.filter { $0.scope.lowercased() == normalizedScope }
            let rest = pool.filter { $0.scope.lowercased() != normalizedScope }
            pool = site + rest
        }
        guard !pool.isEmpty else { return [] }
        let ranked = await retrieveRanked(scoped: pool, query: trimmedQuery)
        return Array(ranked.prefix(max(1, limit)))
    }

    /// **记忆体检**（v0.8.73 批 2）：合并 + 退役 + 报告。被移除的原文先导出
    /// 归档伴生文件（memory-checkup-<时间戳>，数据不丢），逐条记墓碑（同步域
    /// 删除传播），pinned 不动。冲突不清账（走既有复核语义），只在报告里计数。
    @discardableResult
    func runCheckup() -> MemoryCheckupCore.Report {
        let result = MemoryCheckupCore.run(archive.facts, now: Date(),
                                           pendingConflicts: pendingConflicts.count)
        guard !result.removed.isEmpty else { return result.report }
        let stamp = Self.dayStamp(Date())
        DiskStore.save(result.removed, key: "memory-checkup-\(stamp)")
        for fact in result.removed { recordDeletion(fact.id.uuidString) }
        archive.facts = result.kept
        save()
        lastCheckupAt = Date()
        AppPrefs.defaults.set(lastCheckupAt, forKey: Self.lastCheckupKey)
        Log.agent.info("memory checkup: \(result.removed.count) removed (merged \(result.report.mergedRemoved), retired \(result.report.retired))")
        return result.report
    }

    private nonisolated static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // MARK: - 教训效果读数（v0.8.75 批 2，聚合口径）

    /// correction 注入的回合里成功/失败的累计计数——学习闭环有没有效的
    /// 第一读数。**聚合计数，非逐条归因**（回合失败≠教训失败）；点踩仍是
    /// 教训负反馈的唯一自动通道。落 UserDefaults（生命周期累计）。
    struct LessonEffect: Codable, Equatable {
        var appliedOk = 0
        var repeatAfterInject = 0
        var totalInjections = 0
    }

    private static let lessonEffectKey = "memory.lessonEffect"
    private(set) var lessonEffect: LessonEffect = {
        if let data = AppPrefs.defaults.data(forKey: "memory.lessonEffect"),
           let decoded = try? JSONDecoder().decode(LessonEffect.self, from: data) {
            return decoded
        }
        return LessonEffect()
    }()

    func correctionIDs(in ids: [UUID]) -> [UUID] {
        let set = Set(ids)
        return archive.facts.filter { set.contains($0.id) && $0.category == "correction" }.map(\.id)
    }

    func recordLessonEffect(injectedCorrectionIDs: [UUID], turnSucceeded: Bool) {
        guard !injectedCorrectionIDs.isEmpty else { return }
        lessonEffect.totalInjections += 1
        if turnSucceeded {
            lessonEffect.appliedOk += 1
        } else {
            lessonEffect.repeatAfterInject += 1
        }
        if let data = try? JSONEncoder().encode(lessonEffect) {
            AppPrefs.defaults.set(data, forKey: Self.lessonEffectKey)
        }
    }

    /// 体检新鲜度（Doctor 增项②）：上次 runCheckup 的时间戳。
    private static let lastCheckupKey = "memory.lastCheckupAt"
    private(set) var lastCheckupAt: Date? = {
        AppPrefs.defaults.object(forKey: "memory.lastCheckupAt") as? Date
    }()

    // MARK: - 记忆冲突复核（v0.7.22）

    /// 教训提取的节流记账（持久化）：同一天不刷屏。判定复用
    /// SkillCandidateCore.throttlePasses（会话 2/天、全局 6/天）。
    private struct LessonLedger: Codable {
        var offeredAt: [Date]
        var conversationIDs: [UUID]
    }
    private static let lessonLedgerKey = "memory.lessonLedger"
    private var lessonOfferedAt: [Date] = []
    private var lessonConversationIDs: [UUID] = []

    func lessonThrottlePasses(conversationId: UUID?) -> Bool {
        if lessonOfferedAt.isEmpty, lessonConversationIDs.isEmpty,
           let data = AppPrefs.defaults.data(forKey: Self.lessonLedgerKey),
           let decoded = try? JSONDecoder().decode(LessonLedger.self, from: data) {
            lessonOfferedAt = decoded.offeredAt
            lessonConversationIDs = decoded.conversationIDs
        }
        return SkillCandidateCore.throttlePasses(
            offeredAt: lessonOfferedAt, conversationIDs: lessonConversationIDs,
            conversationId: conversationId, now: Date(),
            maxPerDay: 6, perConversation: 2)
    }

    func recordLessonOffered(conversationId: UUID?) {
        if lessonOfferedAt.isEmpty, lessonConversationIDs.isEmpty,
           let data = AppPrefs.defaults.data(forKey: Self.lessonLedgerKey),
           let decoded = try? JSONDecoder().decode(LessonLedger.self, from: data) {
            lessonOfferedAt = decoded.offeredAt
            lessonConversationIDs = decoded.conversationIDs
        }
        lessonOfferedAt.append(Date())
        if let conversationId { lessonConversationIDs.append(conversationId) }
        if let data = try? JSONEncoder().encode(
            LessonLedger(offeredAt: lessonOfferedAt, conversationIDs: lessonConversationIDs)) {
            AppPrefs.defaults.set(data, forKey: Self.lessonLedgerKey)
        }
    }

    // MARK: - 记忆冲突复核（v0.7.22）

    /// 复核决议（面板与桥共用一套语义）。
    enum ConflictResolution: String {
        /// 保留新的：删掉相关旧事实，写入新事实。
        case keepNew
        /// 保留旧的：不写入新事实。
        case keepOld
        /// 两条都保留（近似重复会撞既有去重被拒，属预期）。
        case keepBoth
        /// 合并：删掉相关旧事实，写入合并文本（缺省由纯逻辑兜底拼接）。
        case merge
    }

    struct PendingConflict: Codable, Identifiable, Equatable {
        let id: UUID
        let factID: UUID
        let relatedIDs: [UUID]
    }

    private static let pendingConflictsKey = "memory.pendingConflicts"

    /// 自动抽取路径留下的待复核项（手动添加是即时的、不进队列）。
    @Published private(set) var pendingConflicts: [PendingConflict] = []

    /// 与新增文本相关的既有事实（纯逻辑薄封装；**近似判定**口径见 MemoryConflict）。
    func conflictCandidates(for text: String, category: String, scope: String) -> [MemoryConflict.Candidate] {
        MemoryConflict.candidates(for: text, category: category, scope: scope, facts: archive.facts)
    }

    /// 执行一次复核决议。`relatedIDs` 为空时 keepNew/merge 等同于普通新增。
    /// 删除走既有 recordDeletion（墓碑随同步）；全部改动一次落盘。
    @discardableResult
    func resolveConflict(newText: String, category: String, scope: String, source: String? = nil,
                         resolution: ConflictResolution, relatedIDs: [UUID],
                         mergedText: String? = nil) -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch resolution {
        case .keepOld:
            removePendingConflicts(forFactIDs: [])
            return true
        case .keepBoth:
            addFact(content: trimmed, category: category, scope: scope, source: source)
            return true
        case .keepNew:
            removeFacts(ids: relatedIDs)
            addFact(content: trimmed, category: category, scope: scope, source: source)
            return true
        case .merge:
            removeFacts(ids: relatedIDs)
            let relatedTexts = archive.facts.filter { relatedIDs.contains($0.id) }.map(\.content)
            let merged = (mergedText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? MemoryConflict.defaultMergedText(new: trimmed, related: relatedTexts)
            addFact(content: merged, category: category, scope: scope, source: source)
            return true
        }
    }

    /// 复核态（事实已自动入库）的决议：keepOld = 删掉**新入库的那条**；
    /// keepNew = 删相关旧条；merge = 删两边、写合并文本。队列项同步清掉。
    func resolveReview(factID: UUID, relatedIDs: [UUID], resolution: ConflictResolution,
                       mergedText: String? = nil) {
        guard let fact = archive.facts.first(where: { $0.id == factID }) else {
            removePendingConflicts(forFactIDs: [factID])
            return
        }
        switch resolution {
        case .keepOld:
            removeFacts(ids: [factID])
        case .keepBoth:
            break
        case .keepNew:
            removeFacts(ids: relatedIDs)
        case .merge:
            let relatedTexts = archive.facts.filter { relatedIDs.contains($0.id) }.map(\.content)
            let merged = (mergedText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? MemoryConflict.defaultMergedText(new: fact.content, related: relatedTexts)
            removeFacts(ids: relatedIDs + [factID])
            addFact(content: merged, category: fact.category, scope: fact.scope, source: fact.source)
        }
        removePendingConflicts(forFactIDs: [factID])
        save()
    }

    /// 复核完成/条目不存在时清队列项。
    func removePendingConflicts(forFactIDs ids: [UUID]) {
        if ids.isEmpty { return }
        pendingConflicts.removeAll { ids.contains($0.factID) }
        savePendingConflicts()
    }

    /// 批量决议（v0.7.27）：keepNew = 保留新入库的、删相关旧条；keepOld = 删新入库的。
    /// 队列一次清空、一次落盘；返回处理的条数。
    @discardableResult
    func resolveAllPending(keepingNew: Bool) -> Int {
        let entries = pendingConflicts
        guard !entries.isEmpty else { return 0 }
        for entry in entries {
            guard archive.facts.contains(where: { $0.id == entry.factID }) else { continue }
            if keepingNew {
                removeFacts(ids: entry.relatedIDs)
            } else {
                removeFacts(ids: [entry.factID])
            }
        }
        pendingConflicts.removeAll()
        savePendingConflicts()
        save()
        return entries.count
    }

    /// 清理队列里"引用已不存在"的悬空项（事实被删/被去重拒收后）。
    func prunePendingConflicts() {
        let factIDs = Set(archive.facts.map(\.id))
        let before = pendingConflicts.count
        pendingConflicts.removeAll { entry in
            guard factIDs.contains(entry.factID) else { return true }
            return entry.relatedIDs.allSatisfy { !factIDs.contains($0) }
        }
        if pendingConflicts.count != before { savePendingConflicts() }
    }

    /// 备份导入（v0.7.28）。replace = 整份替换；merge = 只补缺：
    /// 事实按近似重复去重、摘要按会话 id 去重、画像只填空白字段。
    enum ImportMode { case merge, replace }

    @discardableResult
    func importArchive(_ incoming: MemoryArchive, mode: ImportMode) -> (facts: Int, summaries: Int) {
        switch mode {
        case .replace:
            archive = incoming
            save()
            return (incoming.facts.count, incoming.summaries.count)
        case .merge:
            var addedFacts = 0
            for fact in incoming.facts {
                let normalized = MemoryModels.normalizeFact(fact.content)
                let exists = archive.facts.contains {
                    $0.id == fact.id
                        || MemoryModels.areNearDuplicates(MemoryModels.normalizeFact($0.content),
                                                          normalized)
                }
                guard !exists else { continue }
                archive.facts.append(fact)
                addedFacts += 1
            }
            var addedSummaries = 0
            for summary in incoming.summaries
            where !archive.summaries.contains(where: { $0.conversationId == summary.conversationId }) {
                archive.summaries.append(summary)
                addedSummaries += 1
            }
            var profileChanged = false
            if archive.profile.name.isEmpty, !incoming.profile.name.isEmpty {
                archive.profile.name = incoming.profile.name
                profileChanged = true
            }
            if archive.profile.language.isEmpty, !incoming.profile.language.isEmpty {
                archive.profile.language = incoming.profile.language
                profileChanged = true
            }
            if archive.profile.style.isEmpty, !incoming.profile.style.isEmpty {
                archive.profile.style = incoming.profile.style
                profileChanged = true
            }
            if archive.profile.customInstructions.isEmpty,
               !incoming.profile.customInstructions.isEmpty {
                archive.profile.customInstructions = incoming.profile.customInstructions
                profileChanged = true
            }
            if profileChanged { archive.profileUpdatedAt = Date() }
            archive.factsTotalLearned += addedFacts
            // 200 条上限：合并后超出时丢最旧的非 pinned。
            while archive.facts.count > 200,
                  let oldest = archive.facts.lastIndex(where: { !$0.pinned }) {
                archive.facts.remove(at: oldest)
            }
            if addedFacts > 0 || addedSummaries > 0 || profileChanged { save() }
            return (addedFacts, addedSummaries)
        }
    }

    /// 自动抽取路径的备注：入库成功且存在"相关但非近似重复"候选时进队列。
    func noteAutoConflictIfNeeded(insertedFactContent: String, category: String, scope: String) {
        guard let fact = archive.facts.first(where: { $0.content == insertedFactContent.trimmingCharacters(in: .whitespacesAndNewlines) }) else { return }
        let related = MemoryConflict.candidates(for: fact.content, category: category,
                                                scope: scope, facts: archive.facts)
            .filter { $0.factID != fact.id && $0.kind == .related }
            .map(\.factID)
        guard !related.isEmpty else { return }
        pendingConflicts.removeAll { $0.factID == fact.id }
        pendingConflicts.append(PendingConflict(id: UUID(), factID: fact.id, relatedIDs: related))
        savePendingConflicts()
    }

    private func removeFacts(ids: [UUID]) {
        for id in ids {
            recordDeletion(id.uuidString)
            archive.facts.removeAll { $0.id == id }
        }
        removePendingConflicts(forFactIDs: ids)
    }

    private func savePendingConflicts() {
        AppPrefs.defaults.set(try? JSONEncoder().encode(pendingConflicts),
                                  forKey: Self.pendingConflictsKey)
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
    /// been updated (low-engagement cleanup). 使用反馈续命（v0.8.60）：最近
    /// 被使用过的事实按 lastUsedAt 计龄——常带常准的记忆不会被时间清掉。
    /// Returns the count removed.
    @discardableResult
    func decayOldFacts(olderThanDays: Int = 90) -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -olderThanDays, to: Date()) ?? Date()
        let stale = archive.facts.filter { !$0.pinned && effectiveAge($0) < cutoff }
        for fact in stale { removeFact(fact.id) }
        return stale.count
    }

    /// 计龄基准 = updatedAt 与 lastUsedAt 取新（使用即续命）。
    private func effectiveAge(_ fact: MemoryFact) -> Date {
        guard let used = fact.lastUsedAt, used > fact.updatedAt else { return fact.updatedAt }
        return used
    }

    /// **使用反馈**（v0.8.60）：注入过这些事实的回合成功 → 计数+1。
    @discardableResult
    func recordUsage(factIDs: [UUID]) -> Int {
        var touched = 0
        for id in factIDs {
            guard let idx = archive.facts.firstIndex(where: { $0.id == id }) else { continue }
            archive.facts[idx].usageCount = (archive.facts[idx].usageCount ?? 0) + 1
            archive.facts[idx].lastUsedAt = Date()
            touched += 1
        }
        if touched > 0 { save() }
        return touched
    }

    /// 点踩弱化：negativeCount+1（检索分乘降权系数）。
    @discardableResult
    func recordNegative(factIDs: [UUID]) -> Int {
        var touched = 0
        for id in factIDs {
            guard let idx = archive.facts.firstIndex(where: { $0.id == id }) else { continue }
            archive.facts[idx].negativeCount = (archive.facts[idx].negativeCount ?? 0) + 1
            touched += 1
        }
        if touched > 0 { save() }
        return touched
    }

    // MARK: - Prompt injection

    /// The system block injected into every agent request: profile, top
    /// facts (pinned first), and the most recent other-conversation
    /// summaries. Nil when there's nothing to say.
    /// - Parameters:
    ///   - query: 当前对话的检索查询（最近几条 user 消息拼接）。检索 = 向量
    ///     主排（BGEEmbedder 在场时）+ BM25 降级；nil/空 = 最近优先兜底。
    func promptBlock(excluding currentConversation: UUID?, currentHost: String? = nil,
                     query: String? = nil) async -> (block: String?, factIDs: [UUID]) {
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
        // 待复核冲突的新事实**不注入**（v0.7.27）：自动抽取先入库、用户还没确认
        // 哪条对——在那之前当成"不确定"处理，避免把矛盾内容带进系统提示。
        let pendingIDs = Set(pendingConflicts.map(\.factID))
        let scoped = MemoryModels.injectableFacts(archive.facts, pendingIDs: pendingIDs)
            .filter { fact in
                let scope = fact.scope.lowercased()
                return scope.isEmpty || scope == "global"
                    || loweredHost.contains(scope)
                    || scope.hasSuffix("." + loweredHost)
            }
        let facts = await retrieveRanked(scoped: scoped, query: query ?? "")
        Log.agent.info("memory rank: query='\((query ?? "").prefix(60), privacy: .public)' scoped=\(scoped.count, privacy: .public) selected=\(facts.count, privacy: .public) via=\(BGEEmbedder.isAvailable ? "vector" : "bm25", privacy: .public) first='\(facts.first(where: { !$0.pinned })?.content.prefix(40) ?? "-", privacy: .public)'")
        let injectedIDs = facts.map(\.id)
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

        guard !lines.isEmpty else { return (nil, injectedIDs) }
        return ("[User memory — apply silently, never recite]\n"
            + "Save durable user-stated preferences/facts with remember(); search this store on demand with recallMemory(query).\n"
            + lines.joined(separator: "\n"), injectedIDs)
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
