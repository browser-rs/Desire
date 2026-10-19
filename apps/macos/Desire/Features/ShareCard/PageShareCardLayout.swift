import Foundation

/// 网页分享卡的**布局数学与文案清洗**（v0.7.24）：Foundation-only，进 harness。
/// 卡片 = 头部（标题/域名/日期）+ 首屏图（按宽等比）+ 摘要块（纯逻辑折行，
/// 绘制层逐行画同一份结果——单一真相）+ 页脚。单位 = pt（@2x 出图）。
nonisolated enum PageShareCardLayout {
    static let width = 640.0
    static let padding = 24.0
    static let headerHeight = 96.0
    static let footerHeight = 36.0
    static let summaryLineHeight = 19.0
    static let summaryFontSize = 13.0
    static let maxSummaryLines = 4
    static let maxSummaryChars = 240

    /// 摘要清洗：合并空白/去控制字符、去 URL 噪音行，截断到 maxChars（截断处补 …）。
    /// 空/太短（<12 字符）返回 nil（不占版面）。
    static func cleanSummary(_ raw: String, maxChars: Int = maxSummaryChars) -> String? {
        var text = raw
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { line in
                // 纯 URL / 纯符号行不是摘要。
                !(line.hasPrefix("http://") || line.hasPrefix("https://"))
                    && line.contains { $0.isLetter || $0.isNumber }
            }
            .joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        guard text.count >= 12 else { return nil }
        if text.count > maxChars {
            text = String(text.prefix(maxChars - 1)) + "…"
        }
        return text
    }

    /// 按宽度折行：CJK ≈ 1.0 字宽、其余 ≈ 0.56 字宽（估算口径固定、可单测）。
    /// 超 maxLines 时**末行**尾部削到装得下 … 为止（行数恒 = maxLines）。
    static func wrap(_ text: String, maxWidth: Double = width - padding * 2,
                     fontSize: Double = summaryFontSize, maxLines: Int = maxSummaryLines) -> [String] {
        guard !text.isEmpty, maxWidth > 0, fontSize > 0, maxLines > 0 else { return [] }
        func advance(_ ch: Character) -> Double {
            ch.unicodeScalars.allSatisfy { $0.value < 0x2E80 } ? fontSize * 0.56 : fontSize
        }
        var lines: [String] = []
        var current = ""
        var used = 0.0
        var truncated = false
        for ch in text {
            let w = advance(ch)
            if used + w > maxWidth, !current.isEmpty {
                lines.append(current)
                current = ""
                used = 0
                if lines.count == maxLines {
                    truncated = true
                    break
                }
            }
            current.append(ch)
            used += w
        }
        if truncated {
            var last = lines[maxLines - 1]
            var width = last.reduce(0.0) { $0 + advance($1) }
            let ellipsisWidth = fontSize * 0.56
            while !last.isEmpty, width + ellipsisWidth > maxWidth {
                width -= advance(last.removeLast())
            }
            lines[maxLines - 1] = last + "…"
            return lines
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// 卡片总高（含四边内边距；imageHeight = 按卡片宽等比后的高度）。
    static func cardHeight(imageAspect: Double, summaryLineCount: Int) -> Double {
        let imageWidth = width - padding * 2
        let imageHeight = imageAspect > 0 ? imageWidth / imageAspect : 0
        let summaryHeight = summaryLineCount > 0
            ? summaryLineHeight * Double(summaryLineCount) + 12
            : 0
        return padding + headerHeight + imageHeight + summaryHeight + footerHeight + padding
    }
}
