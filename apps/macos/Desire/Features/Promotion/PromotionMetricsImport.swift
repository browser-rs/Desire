import Foundation

/// 平台报表导入（v0.8.3，纯逻辑）：CSV/TSV 文本 → 指标行。
/// 仅在无 DPP 适配/无采集端点时作为兜底；不猜列语义，找不到指标列就明确报错。
///
/// Foundation-only，进 harness。
nonisolated enum PromotionMetricsImport {
    struct Row: Equatable {
        var url: String?
        var title: String?
        var views: Int?
        var likes: Int?
        var comments: Int?
        var date: Date?
        var raw: [String]
    }

    struct ParseResult: Equatable {
        var rows: [Row]
        var errors: [String]
        var delimiter: String
    }

    static func parse(text: String) -> ParseResult {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ParseResult(rows: [], errors: ["Empty file"], delimiter: ",")
        }
        let delimiter = detectDelimiter(clean)
        var table = parseDelimited(clean, delimiter: delimiter)
        guard let header = table.first, table.count >= 2 else {
            return ParseResult(rows: [], errors: ["No data rows found (need a header and at least one row)"],
                               delimiter: String(delimiter))
        }
        table.removeFirst()
        let urlColumn = index(header, aliases: ["url", "link", "链接", "地址", "permalink", "post url", "网页"])
        let titleColumn = index(header, aliases: ["title", "标题", "name", "内容", "post"])
        let viewsColumn = index(header, aliases: ["views", "impressions", "浏览", "播放", "阅读", "曝光", "观看", "view"])
        let likesColumn = index(header, aliases: ["likes", "赞", "点赞", "喜欢", "like"])
        let commentsColumn = index(header, aliases: ["comments", "评论", "回复", "comment"])
        let dateColumn = index(header, aliases: ["date", "日期", "time", "时间", "day"])
        var errors: [String] = []
        if viewsColumn == nil && likesColumn == nil && commentsColumn == nil {
            errors.append("No metric columns found (views/likes/comments)")
        }
        if urlColumn == nil && titleColumn == nil {
            errors.append("No url/title column found — cannot match rows to posts")
        }
        guard errors.isEmpty else {
            return ParseResult(rows: [], errors: errors, delimiter: String(delimiter))
        }

        var rows: [Row] = []
        for cells in table {
            let trimmed = cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard trimmed.contains(where: { !$0.isEmpty }) else { continue }
            func value(_ idx: Int?) -> String? {
                guard let idx, trimmed.indices.contains(idx) else { return nil }
                let v = trimmed[idx]
                return v.isEmpty ? nil : v
            }
            let row = Row(
                url: value(urlColumn),
                title: value(titleColumn),
                views: value(viewsColumn).flatMap(parseNumber),
                likes: value(likesColumn).flatMap(parseNumber),
                comments: value(commentsColumn).flatMap(parseNumber),
                date: value(dateColumn).flatMap(parseDate),
                raw: trimmed)
            if row.views == nil && row.likes == nil && row.comments == nil { continue }
            rows.append(row)
        }
        if rows.isEmpty {
            errors.append("No rows with metric values")
        }
        return ParseResult(rows: rows, errors: errors, delimiter: String(delimiter))
    }

    // MARK: - CSV

    static func detectDelimiter(_ text: String) -> Character {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        let tabs = first.filter { $0 == "\t" }.count
        let semicolons = first.filter { $0 == ";" }.count
        let commas = first.filter { $0 == "," }.count
        if tabs > commas && tabs >= semicolons && tabs > 0 { return "\t" }
        if semicolons > commas && semicolons > 0 { return ";" }
        return ","
    }

    static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let char = text[i]
            if inQuotes {
                if char == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                if char == "\"" {
                    inQuotes = true
                } else if char == delimiter {
                    row.append(field)
                    field = ""
                } else if char == "\n" {
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                } else {
                    field.append(char)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { $0.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) }
    }

    private static func index(_ header: [String], aliases: [String]) -> Int? {
        let lowered = header.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for alias in aliases {
            if let idx = lowered.firstIndex(where: { $0 == alias.lowercased() }) { return idx }
        }
        // 宽松包含匹配（"视频播放数" 含 "播放"）。
        for alias in aliases {
            let needle = alias.lowercased()
            if let idx = lowered.firstIndex(where: { $0.contains(needle) }) { return idx }
        }
        return nil
    }

    /// 数字：去千分位/空格；支持 1.2万 / 1.2w / 12k / 3m / 百万。
    static func parseNumber(_ raw: String) -> Int? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "+", with: "")
        guard !text.isEmpty else { return nil }
        var multiplier: Double = 1
        let suffixes: [(String, Double)] = [
            ("百万", 1_000_000), ("万", 10_000), ("千", 1_000),
            ("m", 1_000_000), ("w", 10_000), ("k", 1_000),
        ]
        let lower = text.lowercased()
        for (suffix, factor) in suffixes where lower.hasSuffix(suffix) {
            multiplier = factor
            text = String(text.dropLast(suffix.count))
            break
        }
        guard let value = Double(text) else { return nil }
        return Int((value * multiplier).rounded())
    }

    static func parseDate(_ raw: String) -> Date? {
        let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm",
                       "MM/dd/yyyy", "dd/MM/yyyy"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// 匹配帖子：优先 URL（忽略末尾斜杠/大小写），其次标题（精确）。
    static func match(row: Row, posts: [PromotionPost]) -> PromotionPost? {
        if let url = row.url?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            if let post = posts.first(where: {
                ($0.url ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == url
            }) { return post }
        }
        if let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            if let post = posts.first(where: { $0.title == title }) { return post }
            return posts.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
        }
        return nil
    }
}
