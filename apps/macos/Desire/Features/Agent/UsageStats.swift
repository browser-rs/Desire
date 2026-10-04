import Foundation

/// 一个统计日：某一天（本地时区、按 `Calendar.startOfDay` 归并）的用量。
struct UsageDayStat: Identifiable {
    let id: Date
    /// 这一天的 token 总量（prompt + completion）。
    let tokens: Int
    /// 这一天的"轮"数：用户发出的消息条数（与面板里一条提问 = 一轮同一口径）。
    let turns: Int
    /// 分模型：模型 id → token（供趋势图按模型画多条线）。子代理这类没有模型归属的
    /// 用量落在 `UsageStats.subagentModelKey`。
    let byModel: [String: Int]
}

/// 一个模型的累计用量（环形图 + 列表）。
struct UsageModelStat: Identifiable {
    /// 模型 id（没有归属的用量用 `UsageStats.subagentModelKey`）。
    let id: String
    let tokens: Int
    let promptTokens: Int
    let completionTokens: Int
    /// 只有这个模型的每一次调用都填了单价才有金额（否则 nil：不显示 $"0"）。
    let cost: Double?
}

/// Token 使用统计：**全部从已存盘的会话派生**（token、模型、时间戳都记在消息上）。
///
/// 与轨迹同一个原则——不另存一份计数，所以统计永远和聊天记录对得上。代价有两条，
/// 都必须在界面上如实说明，否则用户会把它们当成 bug：
/// ① token 是 2026-09-23 才记到消息上的，**更早的历史对话一律记 0**；
/// ② 只有服务端上报用量的调用才有数字（Apple 端上模型不报，那些轮就是 0）。
struct UsageStats {
    /// 没有模型归属的用量（子代理的工具消息、旧会话）在分模型视图里的键。
    static let subagentModelKey = "__unattributed__"

    var totalTokens = 0
    var promptTokens = 0
    var completionTokens = 0
    /// 用户消息条数（"轮"）。
    var turns = 0
    var conversations = 0
    /// 峰值日。
    var peakDayTokens = 0
    var peakDay: Date?
    /// 最长一次对话的时长（首条到末条消息）。
    var longestConversation: TimeInterval = 0
    var currentStreak = 0
    var longestStreak = 0
    /// 有活动的日子（按日期升序；没有活动的日子不出现——热力图自己补空格）。
    var days: [UsageDayStat] = []
    /// 分模型累计（token 降序）。
    var models: [UsageModelStat] = []
    /// 全部调用都能定价时的总金额；有一笔没定价就是 nil（沿用 `AgentUsage` 的规矩）。
    var cost: Double?
    /// 没法定价的 token 数（界面上提示"金额不完整"用）。
    var unpricedTokens = 0

    var isEmpty: Bool { totalTokens == 0 }

    /// `conversations` 用**已存盘的全部会话**；`price` 查单价（没配单价就只有 token）。
    static func derive(from conversations: [Conversation],
                       price: (String?) -> ModelPrice?) -> UsageStats {
        var stats = UsageStats()
        var calendar = Calendar.current
        calendar.timeZone = .current

        // date → 累加器
        struct DayBucket { var tokens = 0; var turns = 0; var byModel: [String: Int] = [:] }
        var buckets: [Date: DayBucket] = [:]
        struct ModelBucket { var tokens = 0; var prompt = 0; var completion = 0; var cost = 0.0; var unpriced = false }
        var modelBuckets: [String: ModelBucket] = [:]

        for conversation in conversations {
            guard !conversation.messages.isEmpty else { continue }
            stats.conversations += 1
            if let first = conversation.messages.first?.createdAt,
               let last = conversation.messages.last?.createdAt {
                stats.longestConversation = max(stats.longestConversation, last.timeIntervalSince(first))
            }
            for message in conversation.messages {
                let day = calendar.startOfDay(for: message.createdAt)
                if message.role == .user {
                    stats.turns += 1
                    buckets[day, default: DayBucket()].turns += 1
                }
                let prompt = message.promptTokens ?? 0
                let completion = message.completionTokens ?? 0
                guard prompt > 0 || completion > 0 else { continue }
                let tokens = prompt + completion
                stats.totalTokens += tokens
                stats.promptTokens += prompt
                stats.completionTokens += completion

                let key = message.model.flatMap { $0.isEmpty ? nil : $0 } ?? subagentModelKey
                buckets[day, default: DayBucket()].tokens += tokens
                buckets[day, default: DayBucket()].byModel[key, default: 0] += tokens
                modelBuckets[key, default: ModelBucket()].tokens += tokens
                modelBuckets[key, default: ModelBucket()].prompt += prompt
                modelBuckets[key, default: ModelBucket()].completion += completion

                if let known = price(key == subagentModelKey ? nil : key),
                   let amount = known.cost(promptTokens: prompt, completionTokens: completion) {
                    stats.cost = (stats.cost ?? 0) + amount
                    modelBuckets[key, default: ModelBucket()].cost += amount
                } else {
                    stats.unpricedTokens += tokens
                    modelBuckets[key, default: ModelBucket()].unpriced = true
                }
            }
        }

        // 有算不进去的调用 → 金额不是总额，别冒充总额。
        if stats.unpricedTokens > 0 { stats.cost = nil }

        stats.days = buckets.map { date, bucket in
            UsageDayStat(id: date, tokens: bucket.tokens,
                         turns: bucket.turns, byModel: bucket.byModel)
        }.sorted { $0.id < $1.id }

        stats.models = modelBuckets.map { key, bucket in
            UsageModelStat(id: key, tokens: bucket.tokens,
                           promptTokens: bucket.prompt, completionTokens: bucket.completion,
                           cost: bucket.unpriced ? nil : bucket.cost)
        }.sorted { $0.tokens > $1.tokens }

        if let peak = stats.days.max(by: { $0.tokens < $1.tokens }), peak.tokens > 0 {
            stats.peakDayTokens = peak.tokens
            stats.peakDay = peak.id
        }

        let streaks = Self.streaks(activeDays: Set(stats.days.filter { $0.tokens > 0 }.map(\.id)),
                                   calendar: calendar)
        stats.currentStreak = streaks.current
        stats.longestStreak = streaks.longest
        return stats
    }

    /// 连续天数：当天有 token 才算"活跃"。**今天还没用不算断**——从今天往回数，
    /// 今天为空时从昨天起算（否则每天早上打开都是 0 天，看着像功能坏了）。
    private static func streaks(activeDays: Set<Date>, calendar: Calendar) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }
        let sorted = activeDays.sorted()

        var longest = 1
        var run = 1
        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let day = sorted[index]
            if calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }

        let today = calendar.startOfDay(for: Date())
        var cursor = activeDays.contains(today)
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today)!
        var current = 0
        while activeDays.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (current, longest)
    }

    /// 某个日期区间（含空日）的逐日用量——热力图与趋势图都从这里取，**保证 x 轴连续**
    /// （没有活动的日子补 0，否则折线会把两周前的用量直接连到昨天）。
    func dayRange(from start: Date, to end: Date) -> [UsageDayStat] {
        let calendar = Calendar.current
        let byDate = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0) })
        var out: [UsageDayStat] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while cursor <= last {
            out.append(byDate[cursor] ?? UsageDayStat(id: cursor, tokens: 0, turns: 0, byModel: [:]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    /// 最近 `count` 天（含今天）的逐日用量。
    func recentDays(_ count: Int) -> [UsageDayStat] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        return dayRange(from: start, to: today)
    }
}
