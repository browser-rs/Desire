import AppKit
import Foundation

enum ScreenshotPhase: Equatable {
    case idle
    case selecting
    case editing(NSImage)

    static func == (lhs: ScreenshotPhase, rhs: ScreenshotPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.selecting, .selecting): return true
        case (.editing, .editing): return true
        default: return false
        }
    }
}

enum ScreenshotTool: String, CaseIterable {
    case rect, ellipse, arrow, pen, text, blur, number, eraser
}

protocol ScreenshotAnnotation {
    func draw(in ctx: CGContext)
}

struct RectAnnotation: ScreenshotAnnotation {
    let rect: CGRect
    let color: NSColor
    let strokeWidth: CGFloat
    let fill: Bool

    func draw(in ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        if fill {
            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
            ctx.addRect(rect)
            ctx.fillPath()
        }
        ctx.addRect(rect)
        ctx.strokePath()
    }
}

struct EllipseAnnotation: ScreenshotAnnotation {
    let rect: CGRect
    let color: NSColor
    let strokeWidth: CGFloat

    func draw(in ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.addEllipse(in: rect)
        ctx.strokePath()
    }
}

struct ArrowAnnotation: ScreenshotAnnotation {
    let start: CGPoint
    let end: CGPoint
    let color: NSColor
    let strokeWidth: CGFloat

    func draw(in ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLen: CGFloat = 12
        ctx.setFillColor(color.cgColor)
        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle - .pi/6), y: end.y - arrowLen * sin(angle - .pi/6)))
        ctx.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle + .pi/6), y: end.y - arrowLen * sin(angle + .pi/6)))
        ctx.closePath()
        ctx.fillPath()
    }
}

struct PenAnnotation: ScreenshotAnnotation {
    let points: [CGPoint]
    let color: NSColor
    let strokeWidth: CGFloat

    func draw(in ctx: CGContext) {
        guard points.count > 1 else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: points[0])
        for p in points.dropFirst() {
            ctx.addLine(to: p)
        }
        ctx.strokePath()
    }
}

struct TextAnnotation: ScreenshotAnnotation {
    let point: CGPoint
    let text: String
    let color: NSColor
    let fontSize: CGFloat

    func draw(in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}

struct BlurAnnotation: ScreenshotAnnotation {
    let rect: CGRect

    func draw(in ctx: CGContext) {
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.fill(rect)
    }
}

struct NumberAnnotation: ScreenshotAnnotation {
    let center: CGPoint
    let number: Int
    let color: NSColor

    func draw(in ctx: CGContext) {
        let radius: CGFloat = 14
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }
}
