import AppKit

/// 摘录分享卡（v0.8.19 融合 13）：单条摘录渲染成精美图片——引文排版
/// （大引号 + 分行正文）+ 来源行 + 强调色渐变底，2x 分辨率。
/// 产物进剪贴板与另存面板双通道。
@MainActor
enum ExcerptShareCard {

    static func render(excerpt: Excerpt, accent: NSColor) -> NSImage {
        let width: CGFloat = 900
        let margin: CGFloat = 64
        let bodyFont = NSFont.systemFont(ofSize: 30, weight: .medium)
        let metaFont = NSFont.systemFont(ofSize: 17)
        let quoteFont = NSFont.systemFont(ofSize: 76, weight: .bold)

        // 正文按宽度折行（逐行累积测量）。
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 10
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
        ]
        let maxWidth = width - margin * 2
        var lines: [String] = []
        for rawLine in excerpt.content.components(separatedBy: "\n") {
            var current = ""
            for word in rawLine.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                let w = (candidate as NSString).size(withAttributes: bodyAttrs).width
                if w > maxWidth, !current.isEmpty {
                    lines.append(current)
                    current = String(word)
                } else {
                    current = candidate
                }
            }
            lines.append(current)
        }

        let bodyLineHeight = bodyFont.ascender - bodyFont.descender + 10
        let bodyHeight = CGFloat(lines.count) * bodyLineHeight
        let noteHeight: CGFloat = (excerpt.note?.isEmpty == false) ? 56 : 0
        let height = margin + quoteFont.capHeight + 14 + bodyHeight + noteHeight + 74 + margin

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        // 底：强调色深浅渐变（深色端保证白字对比）。
        let gradient = NSGradient(
            starting: accent.blended(withFraction: 0.55, of: .black) ?? accent,
            ending: accent.blended(withFraction: 0.25, of: .black) ?? accent)
        gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

        // 大引号。
        let quoteAttrs: [NSAttributedString.Key: Any] = [
            .font: quoteFont, .foregroundColor: NSColor.white.withAlphaComponent(0.35),
        ]
        ("“" as NSString).draw(at: NSPoint(x: margin - 8, y: height - margin - quoteFont.capHeight + 14),
                               withAttributes: quoteAttrs)

        // 正文行。
        var y = height - margin - quoteFont.capHeight + 14 - 26
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: margin, y: y - bodyLineHeight + 10), withAttributes: bodyAttrs)
            y -= bodyLineHeight
        }

        // 我的批注（斜体强调）。
        if let note = excerpt.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]
            ("✦ " + note as NSString).draw(
                at: NSPoint(x: margin, y: y - noteHeight + 10), withAttributes: noteAttrs)
            y -= noteHeight
        }

        // 来源行：kind · title。
        let kindLabel: String
        switch excerpt.kind {
        case .readerHighlight: kindLabel = "阅读"
        case .pdfAnnotation: kindLabel = "PDF"
        case .webSelection: kindLabel = "网页"
        }
        let meta = "\(kindLabel) · \(excerpt.title)" as NSString
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: metaFont, .foregroundColor: NSColor.white.withAlphaComponent(0.65),
        ]
        meta.draw(at: NSPoint(x: margin, y: margin - 8), withAttributes: metaAttrs)
        return image
    }
}
