import Foundation

/// 历史时间线（v0.8.6）的纯逻辑：按天分节、节内按小时聚合访问强度。
/// Foundation-only，进 tests/run.sh。面板"时间线"档共用。
nonisolated enum HistoryTimeline {

    /// 一格 = 一个小时段（0-23）的访问计数。
    struct DayBucket: Equatable {
        /// 本地日 key（yyyy-MM-dd）。
        let dayKey: String
        let date: Date
        /// 24 格；index = 本地小时。
        let hourly: [Int]

        var total: Int { hourly.reduce(0, +) }
        var peakHour: Int? {
            hourly.indices.max { hourly[$0] < hourly[$1] }
        }
    }

    /// 天 key（本地时区）。
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 条目 → 按天聚合的小时直方图，**天序新→旧**；空天不生成（没有访问的
    /// 日子不占版面）。同一天内的小时分布保留在 hourly。
    static func build(from entries: [HistoryEntry],
                      calendar: Calendar = .current,
                      limitDays: Int = 30) -> [DayBucket] {
        var byDay: [String: (date: Date, hourly: [Int])] = [:]
        var dayOrder: [(key: String, date: Date)] = []
        for entry in entries {
            let key = dayKey(entry.timestamp, calendar: calendar)
            if byDay[key] == nil {
                byDay[key] = (entry.timestamp, Array(repeating: 0, count: 24))
                dayOrder.append((key, entry.timestamp))
            }
            let hour = calendar.component(.hour, from: entry.timestamp)
            byDay[key]!.hourly[hour] += 1
        }
        // 天序新→旧（传入序已是新→旧，dayOrder 首见序即最新序）。
        return dayOrder
            .prefix(limitDays)
            .compactMap { key, date in
                guard let bucket = byDay[key] else { return nil }
                return DayBucket(dayKey: key, date: date, hourly: bucket.hourly)
            }
    }
}
