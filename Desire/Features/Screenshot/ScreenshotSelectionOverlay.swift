import AppKit
import SwiftUI

// MARK: - Presenter
enum ScreenshotOverlayPresenter {
    private static weak var activePanel: OverlayPanel?

    static func show(onCancel: @escaping () -> Void, onCapture: @escaping (NSRect) -> Void) {
        hide()
        guard let screen = NSScreen.main else { return }
        let panel = OverlayPanel(screen: screen)
        panel.onCancel = onCancel
        panel.onCapture = onCapture
        panel.orderFrontRegardless()
        activePanel = panel
    }

    static func hide() {
        activePanel?.orderOut(nil)
        activePanel = nil
    }
}

// MARK: - Panel

private class OverlayPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCapture: ((NSRect) -> Void)?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isRestorable = false

        let sel = SelectionView(frame: screen.frame)
        sel.onCancel = { [weak self] in
            self?.onCancel?()
            self?.orderOut(nil)
        }
        sel.onCapture = { [weak self] rect in
            self?.onCapture?(rect)
            self?.orderOut(nil)
        }
        contentView = sel
    }
}

// MARK: - Selection View

private class SelectionView: NSView {
    var onCancel: (() -> Void)?
    var onCapture: ((NSRect) -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(ta)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil; currentPoint = nil; needsDisplay = true }
        guard let start = startPoint, let current = currentPoint else { return }
        let rect = rectBetween(start, current)
        guard rect.width > 5 && rect.height > 5 else { return }
        onCapture?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.fill(bounds)

        if let start = startPoint, let current = currentPoint {
            let rect = rectBetween(start, current)

            ctx.clear(rect)

            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.addRect(rect)
            ctx.strokePath()

            let handleSize: CGFloat = 6
            ctx.setFillColor(NSColor.white.cgColor)
            for corner in [rect.origin,
                           CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY),
                           CGPoint(x: rect.maxX, y: rect.maxY)] {
                ctx.fillEllipse(in: CGRect(x: corner.x - handleSize/2, y: corner.y - handleSize/2, width: handleSize, height: handleSize))
            }

            let dimText = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let textSize = dimText.size(withAttributes: attrs)
            let labelX = rect.midX - textSize.width / 2
            let labelY: CGFloat
            if rect.maxY + 22 + textSize.height < bounds.maxY {
                labelY = rect.maxY + 8
            } else {
                labelY = rect.minY - textSize.height - 8
            }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            let bgRect = CGRect(x: labelX - 4, y: labelY - 2, width: textSize.width + 8, height: textSize.height + 4)
            ctx.fill(bgRect)
            dimText.draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attrs)
        } else {
            let hint = NSLocalizedString("Click and drag to select a region. Esc to cancel.", comment: "")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.white
            ]
            let size = (hint as NSString).size(withAttributes: attrs)
            let point = CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 + 100)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            let bg = CGRect(x: point.x - 10, y: point.y - 6, width: size.width + 20, height: size.height + 12)
            let bgPath = CGPath(roundedRect: bg, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.addPath(bgPath)
            ctx.fillPath()
            (hint as NSString).draw(at: point, withAttributes: attrs)
        }
    }

    private func rectBetween(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
