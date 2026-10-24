import Foundation

/// 每日运营循环的**纯逻辑**（v0.8.4）：从各数据源算出"今天要做的事"，
/// 编号排序后交给编排层执行/汇总。不发布/不回复，只采集与汇总。
///
/// Foundation-only，进 harness。
nonisolated enum OperationsLoopPlan {
    enum ItemKind: String, Comparable {
        case overdueDraft
        case dueRunbook
        case reply
        case competitorChange
        case attributionChange
        case mention

        private var order: Int {
            switch self {
            case .overdueDraft: 0
            case .dueRunbook: 1
            case .reply: 2
            case .mention: 3
            case .competitorChange: 4
            case .attributionChange: 5
            }
        }

        static func < (lhs: ItemKind, rhs: ItemKind) -> Bool { lhs.order < rhs.order }

        var label: String {
            switch self {
            case .overdueDraft: String(localized: "Overdue draft")
            case .dueRunbook: String(localized: "Runbook step due")
            case .reply: String(localized: "Reply waiting")
            case .mention: String(localized: "New mention")
            case .competitorChange: String(localized: "Competitor change")
            case .attributionChange: String(localized: "Attribution change")
            }
        }
    }

    struct Item: Identifiable, Equatable {
        var id: String
        var kind: ItemKind
        var title: String
        var detail: String
        /// 发给 Agent 的行动提示（发布/回复仍需人工批准）。
        var prompt: String
        /// 已完成的条目（循环里不需要再做）。
        var isDone: Bool

        init(id: String, kind: ItemKind, title: String, detail: String = "",
             prompt: String = "", isDone: Bool = false) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.prompt = prompt
            self.isDone = isDone
        }
    }

    struct Report: Equatable {
        var items: [Item]
        var ranAt: Date

        var actionCount: Int { items.filter { !$0.isDone }.count }
        var overdueCount: Int {
            items.filter { !$0.isDone && ($0.kind == .overdueDraft || $0.kind == .dueRunbook) }.count
        }
        var replyCount: Int {
            items.filter { !$0.isDone && $0.kind == .reply }.count
        }

        /// 收件箱/Jobs 的一行摘要（"今日运营：3 件事"）。
        var headline: String {
            actionCount == 0
                ? String(localized: "Operations clear — nothing due")
                : String(format: String(localized: "Operations: %lld item(s)"), actionCount)
        }
    }

    /// 从工作台各数据源收集今日待办。
    /// - Parameters:
    ///   - now: 循环执行时刻。
    ///   - lastRunAt: 上次循环时刻（nil = 首次；提及/竞品只看增量）。
    ///   - attributionDelta: 归因摘要变化描述（nil = 未登录/未部署/无变化）。
    static func collect(
        posts: [PromotionPost],
        campaigns: [PromotionCampaign],
        interactions: [PromotionInteraction],
        competitorSources: [PromotionCompetitorSource],
        attributionDelta: String?,
        now: Date = Date(),
        lastRunAt: Date? = nil
    ) -> Report {
        var items: [Item] = []
        let calendar = Calendar.current
        let entries = PromotionCalendar.entries(
            posts: posts, campaigns: campaigns, now: now, calendar: calendar)
        let queue = PromotionCalendar.todayQueue(entries, now: now, calendar: calendar)

        // ── 逾期草稿 / 到期 Runbook 步骤 ──
        for entry in queue {
            let kind: ItemKind = entry.kind == .draft ? .overdueDraft : .dueRunbook
            let overdueLabel = entry.overdue ? "（逾期）" : ""
            items.append(Item(
                id: entry.id,
                kind: kind,
                title: "\(entry.title)\(overdueLabel)",
                detail: entry.platform,
                prompt: entry.kind == .draft
                    ? "推进排期草稿「\(entry.title)」（\(entry.platform)）：预检后贴最终稿给我确认；发布仍由我批准。"
                    : "执行运营 Runbook 步骤「\(entry.title)」：需要发布/回复的先问我；数据类直接做并汇报。"))
        }

        // ── 待回复互动 ──
        let desk = PromotionReplyDesk.summary(interactions: interactions, now: now)
        if desk.pending > 0 {
            let oldest = interactions
                .filter { $0.status == .pending }
                .min { $0.createdAt < $1.createdAt }
            let detail = oldest.map { item -> String in
                let hours = Int(max(0, now.timeIntervalSince(item.createdAt)) / 3600)
                return String(format: String(localized: "Oldest: %@ on %@ (%lldh)"), item.author, item.platform, hours)
            } ?? ""
            items.append(Item(
                id: "reply-\(desk.pending)",
                kind: .reply,
                title: String(format: String(localized: "%lld reply(ies) waiting"), desk.pending),
                detail: detail,
                prompt: "打开互动台账，按回复台流程逐条拟回复（DPP opsReply 只填不发），贴给我批准。"))
        }

        // ── 新提及（上次循环以来的）──
        let mentionCutoff = lastRunAt ?? now.addingTimeInterval(-24 * 3600)
        let newMentions = interactions.filter {
            $0.kind == .mention && $0.createdAt >= mentionCutoff && $0.status == .pending
        }
        for mention in newMentions.prefix(5) {
            items.append(Item(
                id: "mention-\(mention.id.uuidString)",
                kind: .mention,
                title: String(format: String(localized: "%@ mentioned us on %@"), mention.author, mention.platform),
                detail: String(mention.text.prefix(80)),
                prompt: "处理提及（\(mention.platform) / \(mention.author)）：拟回复或转选题，贴给我确认。"))
        }

        // ── 竞品变化（上次循环以来）──
        for source in competitorSources where source.isEnabled {
            guard let changedAt = source.lastChangeAt, changedAt >= mentionCutoff,
                  let summary = source.lastChangeSummary, !summary.isEmpty else { continue }
            items.append(Item(
                id: "competitor-\(source.id.uuidString)",
                kind: .competitorChange,
                title: String(format: String(localized: "%@ changed"), source.name),
                detail: summary,
                prompt: "竞品「\(source.name)」有变化：\(summary)。评估是否值得转成选题/调整策略。"))
        }

        // ── 归因变化 ──
        if let delta = attributionDelta, !delta.isEmpty {
            items.append(Item(
                id: "attribution-\(Int(now.timeIntervalSince1970))",
                kind: .attributionChange,
                title: String(localized: "Attribution changed"),
                detail: delta,
                prompt: "归因数据变化：\(delta)。把表现好的角度/渠道记为经验，或生成同角度选题。"))
        }

        items.sort { ($0.kind, $0.title) < ($1.kind, $1.title) }
        return Report(items: items, ranAt: now)
    }
}
