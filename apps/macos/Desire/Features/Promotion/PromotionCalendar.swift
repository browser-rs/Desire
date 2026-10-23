import Foundation

/// 运营日历（v0.8.3，纯逻辑）：把草稿排期、已发帖、战役开始日与 Runbook
/// 步骤汇总成同一条时间线。视图只渲染这里的结果，不各自再算一遍。
///
/// Foundation-only，进 harness。
nonisolated enum PromotionCalendar {
    enum Kind: String, Comparable {
        case campaign
        case draft
        case runbook
        case published

        /// 同一天内的展示顺序：战役节点 → 待发 → Runbook → 已发。
        private var order: Int {
            switch self {
            case .campaign: 0
            case .draft: 1
            case .runbook: 2
            case .published: 3
            }
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.order < rhs.order }
    }

    struct Entry: Identifiable, Equatable {
        var id: String
        var date: Date
        var kind: Kind
        var title: String
        var platform: String
        var postID: UUID?
        var campaignID: UUID?
        var stepID: UUID?
        /// 草稿/Runbook 步骤已过期（仅对"待办"类有意义）。
        var overdue: Bool
        var done: Bool

        init(id: String, date: Date, kind: Kind, title: String, platform: String = "",
             postID: UUID? = nil, campaignID: UUID? = nil, stepID: UUID? = nil,
             overdue: Bool = false, done: Bool = false) {
            self.id = id
            self.date = date
            self.kind = kind
            self.title = title
            self.platform = platform
            self.postID = postID
            self.campaignID = campaignID
            self.stepID = stepID
            self.overdue = overdue
            self.done = done
        }
    }

    struct Day: Identifiable, Equatable {
        var date: Date
        var entries: [Entry]
        var isInMonth: Bool
        var isToday: Bool
        var id: Date { date }
    }

    /// 全部日历条目（草稿排期 / 已发 / 战役开始 / Runbook 步骤）。
    static func entries(posts: [PromotionPost], campaigns: [PromotionCampaign],
                        now: Date = Date(), calendar: Calendar = .current) -> [Entry] {
        let today = calendar.startOfDay(for: now)
        var out: [Entry] = []
        for post in posts {
            switch post.status {
            case .published:
                if let at = post.publishedAt {
                    out.append(Entry(id: "post-\(post.id.uuidString)", date: at,
                                     kind: .published, title: post.title,
                                     platform: post.platform, postID: post.id,
                                     campaignID: post.campaignID, done: true))
                }
            case .draft:
                if let planned = post.plannedFor {
                    out.append(Entry(id: "post-\(post.id.uuidString)", date: planned,
                                     kind: .draft, title: post.title,
                                     platform: post.platform, postID: post.id,
                                     campaignID: post.campaignID,
                                     overdue: calendar.startOfDay(for: planned) < today))
                }
            case .idea:
                break
            }
        }
        for campaign in campaigns {
            guard let start = campaign.startsAt else { continue }
            out.append(Entry(id: "campaign-\(campaign.id.uuidString)", date: start,
                             kind: .campaign, title: campaign.title,
                             platform: campaign.platforms.joined(separator: "/"),
                             campaignID: campaign.id))
            for step in campaign.runbook ?? [] {
                let date = PromotionRunbook.date(for: step, start: start, calendar: calendar)
                let done = PromotionRunbook.isComplete(step, campaignID: campaign.id, posts: posts)
                out.append(Entry(id: "step-\(step.id.uuidString)", date: date,
                                 kind: .runbook, title: step.title,
                                 platform: step.platform, campaignID: campaign.id,
                                 stepID: step.id,
                                 overdue: !done && calendar.startOfDay(for: date) < today,
                                 done: done))
            }
        }
        return out.sorted {
            if !calendar.isDate($0.date, inSameDayAs: $1.date) { return $0.date < $1.date }
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// 今天要处理的事：今天到期或已过期的草稿/Runbook 步骤（不含已发/战役节点）。
    static func todayQueue(_ entries: [Entry], now: Date = Date(),
                           calendar: Calendar = .current) -> [Entry] {
        let today = calendar.startOfDay(for: now)
        return entries.filter { entry in
            guard entry.kind == .draft || entry.kind == .runbook else { return false }
            guard !entry.done else { return false }
            let day = calendar.startOfDay(for: entry.date)
            return day <= today
        }
        .sorted {
            if $0.overdue != $1.overdue { return $0.overdue }
            return $0.date < $1.date
        }
    }

    /// 月视图 42 格（6 行 × 7 列），含上下月补位；同一天内条目按类型排序。
    static func monthGrid(containing month: Date, entries: [Entry], now: Date = Date(),
                          calendar: Calendar = .current) -> [Day] {
        let comps = calendar.dateComponents([.year, .month], from: month)
        let first = calendar.date(from: comps) ?? month
        let weekday = calendar.component(.weekday, from: first)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first) ?? first
        let today = calendar.startOfDay(for: now)

        var byDay: [Date: [Entry]] = [:]
        for entry in entries {
            let key = calendar.startOfDay(for: entry.date)
            byDay[key, default: []].append(entry)
        }
        return (0..<42).compactMap { i in
            guard let date = calendar.date(byAdding: .day, value: i, to: start) else { return nil }
            let key = calendar.startOfDay(for: date)
            let list = (byDay[key] ?? []).sorted {
                if $0.kind != $1.kind { return $0.kind < $1.kind }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return Day(date: date, entries: list,
                       isInMonth: calendar.isDate(date, equalTo: first, toGranularity: .month),
                       isToday: key == today)
        }
    }

    /// 当前自然周内某渠道的排期/已发数量（渠道节奏提示用）。
    static func weekCount(platform: String, posts: [PromotionPost],
                          now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let interval = calendar.dateInterval(of: .weekOfMonth, for: now) else { return 0 }
        return posts.filter { post in
            guard post.platform == platform else { return false }
            let date: Date?
            switch post.status {
            case .published: date = post.publishedAt
            case .draft: date = post.plannedFor
            case .idea: date = nil
            }
            guard let date else { return false }
            return interval.contains(date)
        }.count
    }
}
