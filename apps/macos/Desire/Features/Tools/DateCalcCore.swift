import Foundation

/// 日期计算（相差天数/年月日、工作日、日期加减）——纯逻辑。
nonisolated enum DateCalcCore {
    enum Component: String, CaseIterable, Sendable {
        case days
        case weeks
        case months
        case years
    }

    struct Difference: Equatable, Sendable {
        var days: Int
        var weeks: Int
        var months: Int
        var years: Int
        var businessDays: Int
    }

    static func difference(from: Date, to: Date,
                           calendar: Calendar = .current) -> Difference {
        let start = calendar.startOfDay(for: min(from, to))
        let end = calendar.startOfDay(for: max(from, to))
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        let components = calendar.dateComponents([.year, .month, .day], from: start, to: end)
        let totalMonths = (components.year ?? 0) * 12 + (components.month ?? 0)
        return Difference(days: days,
                          weeks: days / 7,
                          months: totalMonths,
                          years: components.year ?? 0,
                          businessDays: businessDays(from: start, to: end, calendar: calendar))
    }

    /// 不含结束日、含起始日的工作日数（周一至周五）。
    static func businessDays(from: Date, to: Date,
                             calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: min(from, to))
        let end = calendar.startOfDay(for: max(from, to))
        guard start < end else { return 0 }
        var count = 0
        var cursor = start
        while cursor < end {
            let weekday = calendar.component(.weekday, from: cursor)
            if weekday != 1 && weekday != 7 { count += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return count
    }

    static func add(_ amount: Int, unit: Component, to date: Date,
                    calendar: Calendar = .current) -> Date? {
        switch unit {
        case .days: return calendar.date(byAdding: .day, value: amount, to: date)
        case .weeks: return calendar.date(byAdding: .day, value: amount * 7, to: date)
        case .months: return calendar.date(byAdding: .month, value: amount, to: date)
        case .years: return calendar.date(byAdding: .year, value: amount, to: date)
        }
    }

    /// 年/月/日拆分展示（如 1 年 2 个月 3 天）。
    static func breakdown(from: Date, to: Date,
                          calendar: Calendar = .current) -> (years: Int, months: Int, days: Int) {
        let start = calendar.startOfDay(for: min(from, to))
        let end = calendar.startOfDay(for: max(from, to))
        let components = calendar.dateComponents([.year, .month, .day], from: start, to: end)
        return (components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
