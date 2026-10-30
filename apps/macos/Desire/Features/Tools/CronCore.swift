import Foundation

/// 5 段 cron 表达式解析与"接下来 N 次运行"——纯逻辑。
/// 支持 *、*/n、a-b、a-b/n、逗号列表；日/周字段都限定时按标准 cron 语义取 OR。
nonisolated enum CronCore {
    struct Expression: Sendable {
        var minutes: Set<Int>
        var hours: Set<Int>
        var daysOfMonth: Set<Int>
        var months: Set<Int>
        var daysOfWeek: Set<Int>
        var domRestricted: Bool
        var dowRestricted: Bool
    }

    static func parse(_ raw: String) -> Result<Expression, ToolboxError> {
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 5 else {
            return .failure(ToolboxError(message: "Expected 5 fields: minute hour day month weekday"))
        }
        do {
            let minutes = try expand(String(fields[0]), min: 0, max: 59)
            let hours = try expand(String(fields[1]), min: 0, max: 23)
            let dom = try expand(String(fields[2]), min: 1, max: 31)
            let months = try expand(String(fields[3]), min: 1, max: 12)
            var dow = try expand(String(fields[4]), min: 0, max: 7)
            if dow.contains(7) {
                dow.remove(7)
                dow.insert(0)
            }
            return .success(Expression(minutes: minutes, hours: hours,
                                       daysOfMonth: dom, months: months,
                                       daysOfWeek: dow,
                                       domRestricted: String(fields[2]) != "*",
                                       dowRestricted: String(fields[4]) != "*"))
        } catch let error as CronError {
            return .failure(ToolboxError(message: error.message))
        } catch {
            return .failure(ToolboxError(message: "Invalid expression"))
        }
    }

    static func nextRuns(_ raw: String, from start: Date = Date(), count: Int = 5,
                         calendar: Calendar = .current) -> Result<[Date], ToolboxError> {
        let expression: Expression
        switch parse(raw) {
        case .failure(let message):
            return .failure(message)
        case .success(let parsed):
            expression = parsed
        }
        var results: [Date] = []
        var cursor = calendar.date(bySetting: .second, value: 0, of: start) ?? start
        cursor = calendar.date(byAdding: .minute, value: 1, to: cursor) ?? cursor
        let limit = 366 * 24 * 60 * 2   // 最多向前找 2 年
        for _ in 0..<limit {
            let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: cursor)
            guard let minute = components.minute, let hour = components.hour,
                  let day = components.day, let month = components.month,
                  let weekday = components.weekday else { break }
            let cronWeekday = weekday - 1   // Calendar: 1=Sunday
            var dayMatches = expression.daysOfMonth.contains(day)
            let dowMatches = expression.daysOfWeek.contains(cronWeekday)
            if expression.domRestricted && expression.dowRestricted {
                dayMatches = dayMatches || dowMatches
            } else if expression.dowRestricted {
                dayMatches = dowMatches
            }
            if expression.minutes.contains(minute),
               expression.hours.contains(hour),
               expression.months.contains(month),
               dayMatches {
                results.append(cursor)
                if results.count >= max(1, count) { return .success(results) }
            }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: cursor) else { break }
            cursor = next
        }
        return .failure(ToolboxError(message: "No run found within 2 years"))
    }

    private struct CronError: Error {
        var message: String
    }

    private static func expand(_ field: String, min: Int, max: Int) throws -> Set<Int> {
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            let piece = String(part)
            let stepSplit = piece.split(separator: "/", omittingEmptySubsequences: false)
            guard stepSplit.count <= 2 else {
                throw CronError(message: "Invalid field: \(piece)")
            }
            let rangePart = String(stepSplit[0])
            var step = 1
            if stepSplit.count == 2 {
                guard let value = Int(stepSplit[1]), value > 0 else {
                    throw CronError(message: "Invalid step: \(piece)")
                }
                step = value
            }
            let bounds: (Int, Int)
            if rangePart == "*" {
                bounds = (min, max)
            } else if rangePart.contains("-") {
                let ends = rangePart.split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count == 2, let lower = Int(ends[0]), let upper = Int(ends[1]),
                      lower >= min, upper <= max, lower <= upper else {
                    throw CronError(message: "Invalid range: \(rangePart)")
                }
                bounds = (lower, upper)
            } else {
                guard let value = Int(rangePart), value >= min, value <= max else {
                    throw CronError(message: "Out of range: \(rangePart) (\(min)-\(max))")
                }
                bounds = (value, value)
            }
            var value = bounds.0
            while value <= bounds.1 {
                result.insert(value)
                value += step
            }
        }
        return result
    }
}
