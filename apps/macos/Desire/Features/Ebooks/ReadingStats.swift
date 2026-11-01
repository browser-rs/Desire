import Foundation

/// 阅读统计（v0.8.35）：按天累计阅读秒数与翻页数，按书记累计；
/// DiskStore 持久化，跨重启保留。Foundation-only 的值类型。
nonisolated struct ReadingStats: Codable, Equatable, Sendable {
    struct Book: Codable, Equatable, Sendable {
        var seconds: Int = 0
        var pages: Int = 0
        var lastReadAt: Date?
    }

    /// yyyy-MM-dd → 秒数
    var days: [String: Int] = [:]
    /// yyyy-MM-dd → 翻页数
    var pagesByDay: [String: Int] = [:]
    /// bookID.uuidString → 按书累计
    var books: [String: Book] = [:]
}
