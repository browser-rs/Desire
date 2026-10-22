import Foundation

/// 浏览器历史行解析。输入是 `sqlite3 -json` 输出的数组（服务层负责用
/// `/usr/bin/sqlite3` 对**副本**查询，避免锁库/TCC 直读原文件）。
nonisolated enum BrowserHistoryParser {
    /// Chromium `urls`：last_visit_time 是 1601-01-01 起的**微秒**。
    static func chromium(data: Data) throws -> [ImportedHistoryEntry] {
        try rows(data, timeKey: "last_visit_time") { raw in
            // microseconds since 1601 → Unix seconds
            raw / 1_000_000.0 - 11_644_473_600.0
        }
    }

    /// Safari `history_items` + `history_visits.visit_time`：2001-01-01 起的秒。
    static func safari(data: Data) throws -> [ImportedHistoryEntry] {
        try rows(data, timeKey: "visit_time") { raw in
            raw + 978_307_200.0
        }
    }

    private static func rows(
        _ data: Data,
        timeKey: String,
        unix: (Double) -> Double
    ) throws -> [ImportedHistoryEntry] {
        guard data.isEmpty || (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw BrowserImportError.malformed("history query did not return JSON")
        }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        let now = Date().timeIntervalSince1970
        var out: [ImportedHistoryEntry] = []
        out.reserveCapacity(array.count)
        for row in array {
            guard let rawURL = (row["url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let scheme = URLComponents(string: rawURL)?.scheme?.lowercased(),
                scheme == "http" || scheme == "https" else { continue }
            let title = ((row["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visitCount = max(1, intValue(row["visit_count"]) ?? 1)
            let rawTime = doubleValue(row[timeKey]) ?? 0
            let seconds = unix(rawTime)
            // Chromium/Safari 的两个纪元换算后应落在合理区间；坏值按"刚刚"
            // 处理，避免 1601/2001 的假时间把历史排序打乱。
            let timestamp = Date(timeIntervalSince1970:
                (seconds > 946_684_800 && seconds < now + 86_400) ? seconds : now)
            out.append(ImportedHistoryEntry(
                url: rawURL,
                title: title.isEmpty ? rawURL : title,
                timestamp: timestamp,
                visitCount: visitCount))
        }
        return out
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let v = any as? Int { return v }
        if let v = any as? Double { return Int(v) }
        if let v = any as? NSNumber { return v.intValue }
        if let v = any as? String { return Int(v) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let v = any as? Double { return v }
        if let v = any as? Int { return Double(v) }
        if let v = any as? NSNumber { return v.doubleValue }
        if let v = any as? String { return Double(v) }
        return nil
    }
}
