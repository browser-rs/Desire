import AppKit
import CoreGraphics

/// 网页分享卡绘制（v0.7.24）：白底卡片 = 头部（标题/域名/日期）+ 首屏图
///（按宽等比裁齐）+ 摘要行（**逐行画 PageShareCardLayout.wrap 的结果**——
/// 折行只有一处真相）+ 页脚。@2x 出图。
@MainActor
enum PageShareCardRenderer {
    static func render(title: String, domain: String, image: NSImage,
                       summaryLines: [String], date: Date = Date()) -> NSImage {
        let width = CGFloat(PageShareCardLayout.width)
        let padding = CGFloat(PageShareCardLayout.padding)
        let headerHeight = CGFloat(PageShareCardLayout.headerHeight)
        let footerHeight = CGFloat(PageShareCardLayout.footerHeight)
        let lineHeight = CGFloat(PageShareCardLayout.summaryLineHeight)
        let imageWidth = width - padding * 2
        let aspect = image.size.width > 0 ? image.size.width / image.size.height : 1.6
        let imageHeight = imageWidth / max(aspect, 0.2)
        let summaryHeight = summaryLines.isEmpty
            ? 0 : lineHeight * CGFloat(summaryLines.count) + 12
        // 高向上取整：@2x 位图 = 点 × 2，小数高度会让像素尺寸与回报的 Int 差 1。
        let height = ceil(padding + headerHeight + imageHeight + summaryHeight + footerHeight + padding)

        let card = NSImage(size: NSSize(width: width, height: height))
        card.lockFocus()
        // 底
        NSColor(red: 0.969, green: 0.973, blue: 0.980, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        // 头部（自上而下）：标题（单行截断）→ 域名 · 日期
        let titleFont = NSFont.systemFont(ofSize: 19, weight: .bold)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1),
        ]
        var titleText = title.isEmpty ? domain : title
        while (titleText as NSString).size(withAttributes: titleAttrs).width > imageWidth, titleText.count > 4 {
            titleText = String(titleText.dropLast(2)) + "…"
        }
        (titleText as NSString).draw(
            at: NSPoint(x: padding, y: height - padding - 26), withAttributes: titleAttrs)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let sub = "\(domain) · \(formatter.string(from: date))" as NSString
        sub.draw(at: NSPoint(x: padding, y: height - padding - 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1),
        ])
        // 首屏图（贴头部之下；lockFocus 坐标系原点在左下，图底 = 卡片高 - 头部区）
        let imageTop = height - padding - headerHeight
        image.draw(in: NSRect(x: padding, y: imageTop - imageHeight,
                              width: imageWidth, height: imageHeight),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1)
        // 摘要行
        if !summaryLines.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: CGFloat(PageShareCardLayout.summaryFontSize)),
                .foregroundColor: NSColor(red: 0.25, green: 0.28, blue: 0.33, alpha: 1),
            ]
            var y = imageTop - imageHeight - 14 - lineHeight + 4
            for line in summaryLines {
                (line as NSString).draw(at: NSPoint(x: padding, y: y), withAttributes: attrs)
                y -= lineHeight
            }
        }
        // 页脚
        ("Desire · 网页分享卡" as NSString).draw(
            at: NSPoint(x: padding, y: padding - 8),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1),
            ])
        card.unlockFocus()
        return card
    }

    static func pngData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
