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
    /// 来源（2026-10-02 个性化增强）：学到该条记忆的会话标题——记忆面板
    /// 可见、可追溯。手动添加为 nil。Optional = 旧数据/同步解码安全。
    var source: String? = nil
    /// **使用反馈**（v0.8.60）：注入后回合成功的次数 / 点踩弱化的次数 /
    /// 最近一次被使用的时间——检索得分乘 usage 提升、decay 按最近使用续命。
    /// Optional = 旧数据/同步解码安全。
    var usageCount: Int? = nil
    var negativeCount: Int? = nil
    var lastUsedAt: Date? = nil

    init(content: String, category: String, pinned: Bool = false, scope: String = "global", source: String? = nil) {
        self.id = UUID()
        self.content = content
        self.category = category
        self.createdAt = Date()
        self.updatedAt = Date()
        self.pinned = pinned
        self.scope = scope
        self.source = source
    }
}

/// L2 — per-conversation summary so past sessions can inform future ones
/// without loading their raw transcripts (L3, already in ConversationStore).
enum MemoryModels {
    /// remember/recallMemory 的 **scope 归一化**（v0.8.72 批 1）：nil/空/
    /// "global" → "global"；URL → 提 host（scope 按 host 注入激活，模型
    /// 传整条 URL 是常态）；其他 → trim + 小写原样。纯逻辑进 tests/run.sh。
    nonisolated static func normalizeScope(_ raw: String?) -> String {
        guard let raw else { return "global" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "global" || trimmed == "all" { return "global" }
        // URL → host：取 scheme// 与第一个 / 之间，再剥端口。
        if trimmed.contains("://") {
            var host = trimmed
            if let schemeRange = host.range(of: "://") {
                host = String(host[schemeRange.upperBound...])
            }
            if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
            if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
            host = host.trimmingCharacters(in: .whitespaces)
            return host.isEmpty ? "global" : host
        }
        return trimmed
    }

    /// 记忆事实的**归一化**：小写、去空白与常见标点 —— 近似重复判定用它。
    nonisolated static func normalizeFact(_ text: String) -> String {
        let lowered = text.lowercased()
        let skipped = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "，。、！？：；\"'()（）[]【】…—,.!?;:"))
        return String(lowered.unicodeScalars.filter { !skipped.contains($0) })
    }

    /// 记忆排序档（v0.8.63 批 1）：最近更新（现状）/ 最常用 / 最近使用——
    /// 使用反馈数据（0.8.60 的 usageCount/lastUsedAt）的排序出口。
    /// pinned 恒在前（与既有语义一致）。纯逻辑进 tests/run.sh。
    enum FactSortOrder: String, CaseIterable {
        case recentlyUpdated
        case mostUsed
        case recentlyUsed

        var title: String {
            switch self {
            case .recentlyUpdated: return String(localized: "Recently updated")
            case .mostUsed: return String(localized: "Most used")
            case .recentlyUsed: return String(localized: "Recently used")
            }
        }
    }

    /// 排序：pinned 恒在前，非 pinned 按所选档排。
    /// recentlyUpdated = updatedAt 降序（既有行为）；mostUsed = usageCount
    /// 降序（平分按生效时间）；recentlyUsed = 生效时间降序（lastUsedAt
    /// 无值回落 updatedAt）。
    static func sortFacts(_ facts: [MemoryFact], order: FactSortOrder) -> [MemoryFact] {
        func effective(_ f: MemoryFact) -> Date {
            guard let used = f.lastUsedAt, used > f.updatedAt else { return f.updatedAt }
            return used
        }
        let pinned = facts.filter { $0.pinned }
        let pool = facts.filter { !$0.pinned }
        switch order {
        case .recentlyUpdated:
            return pinned + pool.sorted { $0.updatedAt > $1.updatedAt }
        case .mostUsed:
            return pinned + pool.sorted {
                let a = $0.usageCount ?? 0
                let b = $1.usageCount ?? 0
                if a != b { return a > b }
                return effective($0) > effective($1)
            }
        case .recentlyUsed:
            return pinned + pool.sorted { effective($0) > effective($1) }
        }
    }

    /// 记忆面板的筛选（v0.7.28）：全部 / 仅 pinned / 仅待复核。
    enum FactFilter: String, CaseIterable {
        case all
        case pinned
        case pending

        var title: String {
            switch self {
            case .all: return String(localized: "All")
            case .pinned: return String(localized: "Pinned")
            case .pending: return String(localized: "Pending review")
            }
        }
    }

    /// 查询匹配 content/category/source（大小写不敏感）；filter 按状态过滤。
    nonisolated static func filterFacts(_ facts: [MemoryFact], query: String,
                                        filter: FactFilter,
                                        pendingIDs: Set<UUID>) -> [MemoryFact] {
        var result = facts
        switch filter {
        case .all:
            break
        case .pinned:
            result = result.filter(\.pinned)
        case .pending:
            result = result.filter { pendingIDs.contains($0.id) }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return result }
        return result.filter { fact in
            fact.content.lowercased().contains(needle)
                || fact.category.lowercased().contains(needle)
                || (fact.source ?? "").lowercased().contains(needle)
        }
    }

    /// 待复核冲突的新事实不进提示（v0.7.27）：用户确认前不参与注入。
    nonisolated static func injectableFacts(_ facts: [MemoryFact],
                                            pendingIDs: Set<UUID>) -> [MemoryFact] {
        pendingIDs.isEmpty ? facts : facts.filter { !pendingIDs.contains($0.id) }
    }

    /// 近似重复判定：字符 bigram 的 Jaccard 相似度 ≥ 0.8 视为重复。
    /// （注释曾写"近似重复"而实现只做精确匹配 —— 语义重复会堆积，
    /// 把 200 条上限挤满。没有端上 embedding，字符 bigram 是够用的下限。）
    nonisolated static func areNearDuplicates(_ a: String, _ b: String) -> Bool {
        return bigramSimilarity(a, b) >= 0.8
    }

    /// bigram Jaccard 相似度（0-1）。体检合并用 0.9 严阈值（见
    /// MemoryCheckupCore），注入去重维持 0.8。
    nonisolated static func bigramSimilarity(_ a: String, _ b: String) -> Double {
        func bigrams(_ t: String) -> Set<String> {
            let chars = Array(t)
            guard chars.count > 1 else { return [t] }
            return Set((0...(chars.count - 2)).map { String(chars[$0...$0 + 1]) })
        }
        let x = bigrams(a), y = bigrams(b)
        if x.isEmpty || y.isEmpty { return a == b ? 1 : 0 }
        let inter = x.intersection(y).count
        let union = x.union(y).count
        return Double(inter) / Double(union)
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
    /// 画像的 LWW 戳（云同步仲裁用；optional = 旧文件缺键解码 nil 不清数据）
    var profileUpdatedAt: Date? = nil
    var facts: [MemoryFact] = []
    var summaries: [ConversationSummary] = []
    var onboardingCompleted = false
    var factsTotalLearned = 0
}
