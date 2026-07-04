import AppKit
import SwiftUI

struct ScreenshotSelectionOverlay: NSViewRepresentable {
    let onCancel: () -> Void
    let onCapture: (NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = OverlayView()
        view.onCancel = onCancel
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private class OverlayView: NSView {
    var onCancel: (() -> Void)?
    var onCapture: ((NSRect) -> Void)?

    private var selectionPanel: ScreenshotSelectionPanel?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            showSelectionPanel()
        } else {
            selectionPanel?.orderOut(nil)
            selectionPanel = nil
        }
    }

    private func showSelectionPanel() {
        guard let screen = NSScreen.main else { return }
        let panel = ScreenshotSelectionPanel(screen: screen)
        panel.onCancel = onCancel
        panel.onCapture = onCapture
        panel.orderFrontRegardless()
        selectionPanel = panel
    }
}

private class ScreenshotSelectionPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onCapture: ((NSRect) -> Void)?

    private var selectionView: SelectionView!

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        selectionView = SelectionView(frame: screen.frame)
        selectionView.onCancel = { [weak self] in
            self?.onCancel?()
            self?.orderOut(nil)
        }
        selectionView.onCapture = { [weak self] rect in
            self?.onCapture?(rect)
            self?.orderOut(nil)
        }
        contentView = selectionView
    }
}

private class SelectionView: NSView {
    var onCancel: (() -> Void)?
    var onCapture: ((NSRect) -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private let dimmingLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(dimmingLayer)
        layer?.addSublayer(selectionLayer)

        dimmingLayer.fillColor = NSColor.black.withAlphaComponent(0.15).cgColor
        dimmingLayer.fillRule = .evenOdd
        selectionLayer.strokeColor = NSColor.white.cgColor
        selectionLayer.fillColor = NSColor.clear.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.shadowColor = NSColor.black.cgColor
        selectionLayer.shadowOffset = .zero
        selectionLayer.shadowRadius = 2
        selectionLayer.shadowOpacity = 0.5
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let end = currentPoint else { return }
        let rect = rectBetween(start, end)
        guard rect.width > 5 && rect.height > 5 else {
            onCancel?()
            return
        }
        onCapture?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private func updateSelection() {
        guard let start = startPoint, let end = currentPoint else {
            selectionLayer.path = nil
            dimmingLayer.path = nil
            return
        }
        let rect = rectBetween(start, end)
        selectionLayer.path = CGPath(rect: rect, transform: nil)
        dimmingLayer.path = dimmingPath(selectedRect: rect)
    }

    private func dimmingPath(selectedRect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(selectedRect)
        return path
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
