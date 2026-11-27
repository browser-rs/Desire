import Foundation

/// 值守周视图（v0.8.83 批 4）：把定时任务运行点与批量/下载时段窗口归并到
/// 7 天网格，标出"拥挤"日与真实重叠。**只读**——不改任何调度设置。
/// 纯 Foundation（harness 覆盖时间线归并与冲突检测）。
nonisolated enum SurveillanceWeek {
    enum Kind: String, Equatable, Sendable {
        case task
        case batch
        case downloads
    }

    struct TaskInput: Equatable, Sendable {
        var name: String
        var rule: ScheduleDue.Rule

        init(name: String, rule: ScheduleDue.Rule) {
            self.name = name
            self.rule = rule
        }
    }

    struct WindowInput: Equatable, Sendable {
        var label: String
        var kind: Kind
        var window: BatchDownloadWindow

        init(label: String, kind: Kind, window: BatchDownloadWindow) {
            self.label = label
            self.kind = kind
            self.window = window
        }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        var id: String
        var kind: Kind
        var label: String
        var start: Date
        var end: Date

        var minutes: Int {
            max(1, Int(end.timeIntervalSince(start) / 60))
        }
    }

    struct Conflict: Identifiable, Equatable, Sendable {
        var id: String
        var day: Date
        var first: String
        var second: String
        var overlapMinutes: Int
    }

    struct Day: Identifiable, Equatable, Sendable {
        var id: Int
        var date: Date
        var entries: [Entry]
        var isCrowded: Bool
        var hasConflict: Bool
    }

    struct Week: Equatable, Sendable {
        var days: [Day]
        var conflicts: [Conflict]
    }

    /// 一个任务运行点按 5 分钟计（UI 上的"点"有可比较的时长，重叠判定才成立）。
    static let taskDuration: TimeInterval = 5 * 60

    static func build(from: Date = Date(),
                      days: Int = 7,
                      calendar: Calendar = .current,
                      tasks: [TaskInput],
                      windows: [WindowInput],
                      crowdedThreshold: Int = 4) -> Week {
        let count = max(1, days)
        let firstDay = calendar.startOfDay(for: from)
        var result: [Day] = []
        var conflicts: [Conflict] = []

        for offset in 0..<count {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                continue
            }
            var entries: [Entry] = []

            // 任务运行点：从当天 00:00 之前一点点开始取，过滤进当天。
            for task in tasks {
                let runs = TaskCalendar.upcoming(rule: task.rule,
                                                 after: dayStart.addingTimeInterval(-1),
                                                 count: 48,
                                                 calendar: calendar)
                for run in runs where run >= dayStart && run < dayEnd {
                    entries.append(Entry(
                        id: "task:\(task.name):\(Int(run.timeIntervalSince1970))",
                        kind: .task,
                        label: task.name,
                        start: run,
                        end: run.addingTimeInterval(taskDuration)))
                }
            }

            // 时段窗口：每天重复；跨午夜的拆两段，重叠判定才准确。
            for input in windows {
                let window = input.window
                if window.startMinute == window.endMinute {
                    entries.append(Entry(
                        id: "\(input.kind.rawValue):\(input.label):\(offset):all",
                        kind: input.kind, label: input.label,
                        start: dayStart, end: dayEnd))
                    continue
                }
                let start = dayStart.addingTimeInterval(Double(window.startMinute) * 60)
                let end = dayStart.addingTimeInterval(Double(window.endMinute) * 60)
                if window.startMinute < window.endMinute {
                    entries.append(Entry(
                        id: "\(input.kind.rawValue):\(input.label):\(offset)",
                        kind: input.kind, label: input.label,
                        start: start, end: end))
                } else {
                    // 例如 22:00–06:00：当天 22:00–24:00 + 当天 00:00–06:00。
                    entries.append(Entry(
                        id: "\(input.kind.rawValue):\(input.label):\(offset):eve",
                        kind: input.kind, label: "\(input.label) →",
                        start: start, end: dayEnd))
                    entries.append(Entry(
                        id: "\(input.kind.rawValue):\(input.label):\(offset):morn",
                        kind: input.kind, label: "← \(input.label)",
                        start: dayStart, end: end))
                }
            }

            entries.sort { a, b in
                if a.start != b.start { return a.start < b.start }
                return a.label < b.label
            }

            // 两两比较：真实重叠（> 0 分钟）才算冲突；同一对只记一次。
            var dayConflicts: [Conflict] = []
            if entries.count > 1 {
                for i in 0..<(entries.count - 1) {
                    for j in (i + 1)..<entries.count {
                        let a = entries[i], b = entries[j]
                        let overlap = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
                        guard overlap > 0 else { continue }
                        dayConflicts.append(Conflict(
                            id: "\(a.id)|\(b.id)",
                            day: dayStart,
                            first: a.label,
                            second: b.label,
                            overlapMinutes: max(1, Int(overlap / 60))))
                    }
                }
            }
            dayConflicts.sort {
                if $0.overlapMinutes != $1.overlapMinutes {
                    return $0.overlapMinutes > $1.overlapMinutes
                }
                return $0.id < $1.id
            }
            conflicts.append(contentsOf: dayConflicts.prefix(12))

            result.append(Day(id: offset, date: dayStart, entries: entries,
                              isCrowded: entries.count > crowdedThreshold,
                              hasConflict: !dayConflicts.isEmpty))
        }

        // 全局只留最严重的 20 条，避免长窗口把列表刷爆。
        conflicts.sort {
            if $0.overlapMinutes != $1.overlapMinutes {
                return $0.overlapMinutes > $1.overlapMinutes
            }
            return $0.id < $1.id
        }
        return Week(days: result, conflicts: Array(conflicts.prefix(20)))
    }
}
