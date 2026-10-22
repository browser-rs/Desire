import Foundation

/// 页面监视的噪声归一（v0.8.1，纯逻辑，进 tests/run.sh）。
///
/// 网页上大量“变化”不是内容变化：时间戳、相对时间（3 分钟前）、访问/点赞
/// 计数。直接对文本做 diff 会把这些当成更新，用户收到的通知几乎都是噪声
/// （用户实测：时钟/计数每轮都变）。这里在归一化阶段把它们替换成占位符——
/// **只掩码带明确时间/单位语义的数字**，正文里的普通数字保留（价格这类
/// 精确盯梢走 numericSelector，不靠文本 diff）。
nonisolated enum PageWatchNoise {
    static func normalize(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r", with: "")
        value = value.split(whereSeparator: \.isNewline).joined(separator: "\n")
        value = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        value = mask(value)
        value = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 逐条替换（顺序有意义：先日期时间，再相对时间，最后带单位计数）。
    static func mask(_ text: String) -> String {
        var value = text
        value = replace(value, pattern:
            #"\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}(?:[ T]\d{1,2}:\d{2}(?::\d{2})?)?\b"#,
            with: "[date]")
        value = replace(value, pattern:
            #"\b\d{1,2}:\d{2}(?::\d{2})?\b"#,
            with: "[time]")
        value = replace(value, pattern:
            #"\d{4}\s*年\s*\d{1,2}\s*月\s*\d{1,2}\s*日|\d{1,2}\s*月\s*\d{1,2}\s*日"#,
            with: "[date]")
        value = replace(value, pattern:
            #"(?:刚刚|\b\d+\s*(?:秒|分钟|小时|天|周|个月|年)\s*前|\b\d+\s*(?:seconds?|minutes?|hours?|days?|weeks?|months?|years?)\s+ago\b)"#,
            with: "[relative time]", options: [.caseInsensitive])
        // 千分位/带单位计数：1,234 / 2.3K / 45 次 / 1.2M views…
        value = replace(value, pattern: #"\b\d{1,3}(?:,\d{3})+\b"#,
                        with: "[count]")
        value = replace(value, pattern:
            #"\b\d+(?:\.\d+)?\s*(?:次|浏览|观看|播放|点赞|评论|粉丝|关注|阅读|views?|likes?|comments?|plays?|reads?|followers?|subscribers?)"#,
            with: "[count]", options: [.caseInsensitive])
        return value
    }

    private static func replace(_ text: String, pattern: String,
                                with template: String,
                                options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range,
                                              withTemplate: template)
    }
}
