import Foundation

/// 定时任务的"该不该跑 / 是不是补跑"判定（v0.8.81 批 3）。
///
/// 抽成 Foundation-only 的纯逻辑：调度器只负责投递，时间算术与补跑语义
/// 可以离线单测（`tests/main.swift`）。三条约定：
/// - **间隔任务**：错过多少个周期都只跑一次（不是补一串）；
/// - **每日任务**：当天到点后跑；超过宽限（默认 5 分钟）算补跑；
/// - **每周任务**：按"最近一次应跑时刻"判定——机器整周关机后，下次启动
///   仍会补跑一次；但若下一次应跑时刻已很近（≤ 2 小时），让下一次正常跑，
///   避免刚补完又立刻按正常周期跑一遍。
///
/// `catchUpEnabled == false` 时只保留"准点窗口内"的投递：每日/每周超过
/// 宽限就不再触发（下一次正常时刻照常）。
nonisolated enum ScheduleDue {
    enum Rule: Equatable, Sendable {
        case everyMinutes(Int)
        case daily(hour: Int, minute: Int)
        case weekly(weekday: Int, hour: Int, minute: Int)
    }

    struct Decision: Equatable, Sendable {
        let isDue: Bool
        /// 这一次是对"已经错过的应跑时刻"的补偿（面板/运行记录会标注）。
        let isCatchUp: Bool
        /// 触发所对应的应跑时刻（间隔任务 = 上次应跑时刻；每日/每周 = 当天/本周时刻）。
        let scheduledAt: Date?
        /// 错过多少次（间隔任务可 > 1；每日/每周按应跑时刻算一次）。
        let missedCount: Int
    }

    static let defaultGraceSeconds: TimeInterval = 300
    static let defaultWeeklyMinGapSeconds: TimeInterval = 7_200

    static func evaluate(rule: Rule,
                         createdAt: Date,
                         lastFiredAt: Date?,
                         now: Date,
                         calendar: Calendar = .current,
                         catchUpEnabled: Bool = true,
                         graceSeconds: TimeInterval = defaultGraceSeconds,
                         weeklyMinGapSeconds: TimeInterval = defaultWeeklyMinGapSeconds) -> Decision {
        let last = lastFiredAt ?? createdAt
        switch rule {
        case .everyMinutes(let minutes):
            let interval = Double(max(5, minutes)) * 60
            let elapsed = now.timeIntervalSince(last)
            guard elapsed >= interval else {
                return Decision(isDue: false, isCatchUp: false, scheduledAt: nil, missedCount: 0)
            }
            let missed = max(1, Int(floor(elapsed / interval)))
            let scheduled = last.addingTimeInterval(interval)
            // 间隔任务的"错过"只是启动/唤醒晚了一点，跑一次即回到节奏；
            // 关掉补跑开关不能让它永远不跑（下一次判定仍会超期）。
            let catchUp = elapsed > interval + graceSeconds
            return Decision(isDue: true, isCatchUp: catchUp,
                            scheduledAt: scheduled, missedCount: missed)

        case .daily(let hour, let minute):
            guard let todayAt = occurrence(on: now, hour: hour, minute: minute,
                                           calendar: calendar) else {
                return Decision(isDue: false, isCatchUp: false, scheduledAt: nil, missedCount: 0)
            }
            let sameDay = calendar.isDate(last, inSameDayAs: now)
            guard now >= todayAt, !sameDay else {
                return Decision(isDue: false, isCatchUp: false, scheduledAt: todayAt,
                                missedCount: 0)
            }
            let late = now.timeIntervalSince(todayAt)
            let catchUp = late > graceSeconds
            if catchUp, !catchUpEnabled {
                return Decision(isDue: false, isCatchUp: false, scheduledAt: todayAt,
                                missedCount: 0)
            }
            return Decision(isDue: true, isCatchUp: catchUp,
                            scheduledAt: todayAt, missedCount: 1)

        case .weekly(let weekday, let hour, let minute):
            guard let occurrence = previousWeeklyOccurrence(weekday: weekday, hour: hour,
                                                            minute: minute, now: now,
                                                            calendar: calendar) else {
                return Decision(isDue: false, isCatchUp: false, scheduledAt: nil, missedCount: 0)
            }
            guard last < occurrence else {
                return Decision(isDue: false, isCatchUp: false, scheduledAt: occurrence,
                                missedCount: 0)
            }
            let late = now.timeIntervalSince(occurrence)
            let catchUp = late > graceSeconds
            if catchUp {
                // 下一次应跑时刻很近（例如周一 08:00 打开、09:00 就是本周的
                // 正常时刻）→ 让正常时刻跑，别在 08:00 补一次 09:00 又跑一次。
                let next = occurrence.addingTimeInterval(7 * 86_400)
                if next.timeIntervalSince(now) <= weeklyMinGapSeconds {
                    return Decision(isDue: false, isCatchUp: false,
                                    scheduledAt: occurrence, missedCount: 0)
                }
                if !catchUpEnabled {
                    return Decision(isDue: false, isCatchUp: false,
                                    scheduledAt: occurrence, missedCount: 1)
                }
            }
            return Decision(isDue: true, isCatchUp: catchUp,
                            scheduledAt: occurrence, missedCount: 1)
        }
    }

    // MARK: - Calendar helpers

    private static func occurrence(on date: Date, hour: Int, minute: Int,
                                   calendar: Calendar) -> Date? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(year: parts.year, month: parts.month,
                                                  day: parts.day, hour: hour, minute: minute))
    }

    /// 最近一次**已经到达**的每周应跑时刻（今天还没到就退回上周）。
    private static func previousWeeklyOccurrence(weekday: Int, hour: Int, minute: Int,
                                                 now: Date,
                                                 calendar: Calendar) -> Date? {
        guard let todayAt = occurrence(on: now, hour: hour, minute: minute,
                                       calendar: calendar) else { return nil }
        let delta = (calendar.component(.weekday, from: now) - weekday + 7) % 7
        guard var candidate = calendar.date(byAdding: .day, value: -delta,
                                            to: todayAt) else { return nil }
        if candidate > now {
            guard let previous = calendar.date(byAdding: .day, value: -7,
                                               to: candidate) else { return nil }
            candidate = previous
        }
        return candidate
    }
}
