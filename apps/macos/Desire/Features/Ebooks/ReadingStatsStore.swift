import Combine
import Foundation

/// 阅读统计存储（v0.8.35）：阅读器 30 秒心跳 + 退出结算写入。
@MainActor
final class ReadingStatsStore: ObservableObject {
    static let shared = ReadingStatsStore()

    static let diskKey = "ebooks.readingStats"

    @Published private(set) var stats = ReadingStats()

    private init() {
        stats = DiskStore.load(ReadingStats.self, key: Self.diskKey) ?? ReadingStats()
    }

    func add(bookID: UUID, seconds: Int, pages: Int) {
        guard seconds > 0 || pages > 0 else { return }
        let key = Self.dayKey(for: Date())
        if seconds > 0 {
            stats.days[key, default: 0] += seconds
        }
        if pages > 0 {
            stats.pagesByDay[key, default: 0] += pages
        }
        let bookKey = bookID.uuidString
        var book = stats.books[bookKey] ?? ReadingStats.Book()
        book.seconds += max(0, seconds)
        book.pages += max(0, pages)
        book.lastReadAt = Date()
        stats.books[bookKey] = book
        DiskStore.save(stats, key: Self.diskKey)
    }

    var totalSeconds: Int {
        stats.days.values.reduce(0, +)
    }

    var totalPages: Int {
        stats.pagesByDay.values.reduce(0, +)
    }

    /// 今天往前 7 天（含今天）的秒数。
    var weekSeconds: Int {
        let calendar = Calendar.current
        let today = Date()
        var total = 0
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            total += stats.days[Self.dayKey(for: day)] ?? 0
        }
        return total
    }

    /// 连续阅读天数：今天有记录就从今天数，否则从昨天数。
    var streakDays: Int {
        let calendar = Calendar.current
        var cursor = Date()
        if (stats.days[Self.dayKey(for: cursor)] ?? 0) <= 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while (stats.days[Self.dayKey(for: cursor)] ?? 0) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// 最近 N 天（从旧到新）的每日秒数。
    func recentDays(_ count: Int = 14) -> [(date: Date, seconds: Int)] {
        let calendar = Calendar.current
        let today = Date()
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (date: calendar.startOfDay(for: day),
                    seconds: stats.days[Self.dayKey(for: day)] ?? 0)
        }
    }

    static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
