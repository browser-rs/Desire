import Combine
import Foundation

/// 阅读统计存储（v0.8.35）：阅读器 30 秒心跳 + 退出结算写入。
@MainActor
final class ReadingStatsStore: ObservableObject {
    static let shared = ReadingStatsStore()

    static let diskKey = "ebooks.readingStats"

    @Published private(set) var stats = ReadingStats()
    /// 本机原始统计（推给别的设备用）；`stats` 是合并后的展示口径。
    private(set) var ownStats = ReadingStats()

    private static let ownKey = "ebooks.readingStats.own"

    private init() {
        stats = DiskStore.load(ReadingStats.self, key: Self.diskKey) ?? ReadingStats()
        ownStats = DiskStore.load(ReadingStats.self, key: Self.ownKey) ?? stats
        if DiskStore.load(ReadingStats.self, key: Self.ownKey) == nil {
            DiskStore.save(ownStats, key: Self.ownKey)
        }
    }

    func add(bookID: UUID, seconds: Int, pages: Int) {
        guard seconds > 0 || pages > 0 else { return }
        let key = Self.dayKey(for: Date())
        func apply(_ target: inout ReadingStats) {
            if seconds > 0 { target.days[key, default: 0] += seconds }
            if pages > 0 { target.pagesByDay[key, default: 0] += pages }
            let bookKey = bookID.uuidString
            var book = target.books[bookKey] ?? ReadingStats.Book()
            book.seconds += max(0, seconds)
            book.pages += max(0, pages)
            book.lastReadAt = Date()
            target.books[bookKey] = book
        }
        apply(&ownStats)
        apply(&stats)
        DiskStore.save(ownStats, key: Self.ownKey)
        DiskStore.save(stats, key: Self.diskKey)
    }

    /// 本机原始统计 → 同步 payload（书 id 换 hash）。
    func syncPayload(deviceID: String) -> ReadingStatsPayload {
        var booksByHash: [String: ReadingStats.Book] = [:]
        for (key, value) in ownStats.books {
            guard let id = UUID(uuidString: key),
                  let book = EbookLibraryStore.shared.book(id: id) else { continue }
            booksByHash[book.hash] = value
        }
        return ReadingStatsPayload(deviceID: deviceID,
                                   days: ownStats.days,
                                   pagesByDay: ownStats.pagesByDay,
                                   books: booksByHash,
                                   updatedAt: Date())
    }

    /// 远端设备统计落地：按天/按书取 max，不改 ownStats。
    func applySyncPayload(_ payload: ReadingStatsPayload) {
        stats.days = ReadingStatsSyncCore.mergeDays(stats.days, payload.days)
        stats.pagesByDay = ReadingStatsSyncCore.mergeDays(
            stats.pagesByDay, payload.pagesByDay)
        for (hash, remote) in payload.books {
            guard let local = EbookLibraryStore.shared.books.first(where: {
                $0.hash.lowercased() == hash.lowercased()
            }) else { continue }
            let key = local.id.uuidString
            stats.books[key] = ReadingStatsSyncCore.mergeBook(stats.books[key], remote)
        }
        DiskStore.save(stats, key: Self.diskKey)
        objectWillChange.send()
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
