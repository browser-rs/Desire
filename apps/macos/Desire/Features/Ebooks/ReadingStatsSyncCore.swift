import Foundation

/// 跨设备阅读统计（v0.8.37）：每台设备推自己的原始统计，客户端按天/按书取 max。
/// 取 max 而非相加——同一天两台设备都读 30 分钟，合并口径是 30 分钟。
nonisolated struct ReadingStatsPayload: Codable, Equatable, Sendable {
    var deviceID: String
    var days: [String: Int]
    var pagesByDay: [String: Int]
    /// book hash → 该设备原始累计
    var books: [String: ReadingStats.Book]
    var updatedAt: Date
}

nonisolated enum ReadingStatsSyncCore {

    static func mergeDays(_ local: [String: Int],
                          _ remote: [String: Int]) -> [String: Int] {
        var out = local
        for (key, value) in remote {
            out[key] = max(out[key] ?? 0, value)
        }
        return out
    }

    static func mergeBook(_ local: ReadingStats.Book?,
                          _ remote: ReadingStats.Book) -> ReadingStats.Book {
        guard var result = local else { return remote }
        result.seconds = max(result.seconds, remote.seconds)
        result.pages = max(result.pages, remote.pages)
        if let remoteDate = remote.lastReadAt,
           remoteDate > (result.lastReadAt ?? .distantPast) {
            result.lastReadAt = remoteDate
        }
        return result
    }
}
