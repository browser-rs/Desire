import Foundation

/// 研究简报的纯数据模型（v0.8.50 批 1）。Foundation-only、进 tests/run.sh。
///
/// 引用契约的核心：`sources` 的 `id` 就是正文里的 `[n]`；编号由宿主按顺序
/// 重建，**不信任模型自排**。来源可以是"抓取成功"（有 excerpt）或"失败"
/// （`note` 记归因：gated / timeout / 404 / empty）。

nonisolated enum ResearchBriefTemplate: String, Codable, CaseIterable, Identifiable {
    case summary
    case compare
    case timeline

    var id: String { rawValue }

    /// 给模型的分节骨架提示（输出语言由 document.language 控制）。
    var sectionHint: String {
        switch self {
        case .summary:
            return "Sections: overview (2-3 paragraphs), key points (bulleted, each bullet cites [n]), limitations."
        case .compare:
            return "Sections: dimensions (what is being compared), comparison table (rows = dimensions, columns = subjects, cells cite [n]), verdict."
        case .timeline:
            return "Sections: timeline (chronological events, each cites [n]), impact, outlook."
        }
    }
}

nonisolated struct ResearchBriefSource: Codable, Identifiable, Equatable {
    /// 1-based：正文里就是 `[id]`。
    var id: Int
    var title: String
    var url: String
    var domain: String
    var publishedAt: String?
    var fetchedAt: Date
    /// 阅读模式提取的正文（有上限）；失败来源为空串。
    var excerpt: String
    /// 登录墙/付费墙（抓不到正文，但保留在来源列表并标注）。
    var gated: Bool
    /// 失败归因（gated / timeout / http-404 / empty / budget），成功为 nil。
    var note: String?
}

nonisolated struct ResearchBriefSection: Codable, Equatable {
    var heading: String
    var markdown: String
}

nonisolated struct ResearchBriefPoint: Codable, Equatable {
    var sourceID: Int
    var point: String
    var quote: String
    /// 引文是否在源正文中逐字命中（归一化后精确匹配）。
    var verified: Bool
}

nonisolated struct ResearchBriefDocument: Codable, Identifiable, Equatable {
    enum State: String, Codable, CaseIterable {
        case queued, planning, fetching, reading, composing, done, failed, cancelled

        var isActive: Bool {
            switch self {
            case .queued, .planning, .fetching, .reading, .composing: return true
            case .done, .failed, .cancelled: return false
            }
        }
    }

    var id = UUID()
    var topic: String
    /// BCP-47-ish："zh-Hans" / "en"；决定产出语言与宿主标签语言。
    var language: String = "zh-Hans"
    var template: ResearchBriefTemplate = .summary
    /// 目标来源数（3-12）。
    var depth: Int = 6
    var state: State = .queued
    var createdAt = Date()
    var updatedAt = Date()
    var sources: [ResearchBriefSource] = []
    var sections: [ResearchBriefSection] = []
    var points: [ResearchBriefPoint] = []
    var unverifiedQuotes = 0
    var droppedRefs = 0
    var uncitedBullets = 0
    var truncatedByBudget = false
    var tokensUsed = 0
    var error: String?

    var isChinese: Bool { language.lowercased().hasPrefix("zh") }
}
