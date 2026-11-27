import Foundation

/// 定时任务的下一次运行（v0.8.82 批 2）：纯时间算术，面板日历与桥共用。
/// 只回答“从 after 之后的 count 次应跑时刻”，不关心 lastFiredAt/补跑；
/// 补跑仍由 `ScheduleDue` 判定。
nonisolated enum TaskCalendar {
    static func upcoming(rule: ScheduleDue.Rule, after: Date, count: Int,
                         calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        switch rule {
        case .everyMinutes(let minutes):
            let interval = Double(max(5, minutes)) * 60
            return (1...count).map { after.addingTimeInterval(interval * Double($0)) }

        case .daily(let hour, let minute):
            guard var candidate = occurrence(on: after, hour: hour, minute: minute,
                                             calendar: calendar) else { return [] }
            if candidate <= after {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            var out: [Date] = []
            for _ in 0..<count {
                guard candidate > after else { break }
                out.append(candidate)
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return out

        case .weekly(let weekday, let hour, let minute):
            guard let todayAt = occurrence(on: after, hour: hour, minute: minute,
                                           calendar: calendar) else { return [] }
            let delta = (weekday - calendar.component(.weekday, from: after) + 7) % 7
            var candidate = calendar.date(byAdding: .day, value: delta, to: todayAt) ?? todayAt
            if candidate <= after {
                candidate = calendar.date(byAdding: .day, value: 7, to: candidate) ?? candidate
            }
            var out: [Date] = []
            for _ in 0..<count {
                guard candidate > after else { break }
                out.append(candidate)
                candidate = calendar.date(byAdding: .day, value: 7, to: candidate) ?? candidate
            }
            return out
        }
    }

    private static func occurrence(on date: Date, hour: Int, minute: Int,
                                   calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month,
                                                  day: parts.day, hour: hour, minute: minute))
    }
}
