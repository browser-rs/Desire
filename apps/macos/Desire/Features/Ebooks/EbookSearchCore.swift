import Foundation

/// 书内搜索纯逻辑（v0.8.34）：HTML → 纯文本、逐章命中与片段。
/// Foundation-only，进 tests/run.sh。
nonisolated enum EbookSearchCore {

    struct ChapterText: Sendable, Equatable {
        var index: Int
        var title: String
        var text: String
    }

    struct Hit: Identifiable, Equatable, Sendable {
        var chapterIndex: Int
        var chapterTitle: String
        var snippet: String
        var offset: Int
        var id: String { "\(chapterIndex)-\(offset)" }
    }

    /// 去掉脚本/样式/标签并解码常见实体；空白折叠成单空格。
    static func plainText(fromHTML html: String) -> String {
        var text = html
        let patterns: [(String, String)] = [
            ("<script\\b[^>]*>[\\s\\S]*?</script>", " "),
            ("<style\\b[^>]*>[\\s\\S]*?</style>", " "),
            ("<[^>]+>", " "),
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
        ]
        for (pattern, replacement) in patterns {
            text = text.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive])
        }
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 大小写不敏感逐章搜索；每章最多 perChapter 条，总计最多 limit 条。
    static func search(query: String, chapters: [ChapterText],
                       perChapter: Int = 3, limit: Int = 80) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 1 else { return [] }
        var hits: [Hit] = []
        for chapter in chapters {
            var cursor = chapter.text.startIndex
            var found = 0
            while found < perChapter,
                  let range = chapter.text.range(of: needle, options: .caseInsensitive,
                                                 range: cursor..<chapter.text.endIndex) {
                let lower = chapter.text.distance(from: chapter.text.startIndex,
                                                  to: range.lowerBound)
                let snippet = snippet(in: chapter.text, around: range,
                                      radius: 54)
                hits.append(Hit(chapterIndex: chapter.index, chapterTitle: chapter.title,
                                snippet: snippet, offset: lower))
                found += 1
                cursor = range.upperBound
                if cursor >= chapter.text.endIndex { break }
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    private static func snippet(in text: String, around range: Range<String.Index>,
                                radius: Int) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -radius,
                               limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: radius,
                               limitedBy: text.endIndex) ?? text.endIndex
        var piece = String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if lower != text.startIndex { piece = "…" + piece }
        if upper != text.endIndex { piece += "…" }
        return piece
    }
}
