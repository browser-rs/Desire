import AppKit

/// 选区 overlay。在 NSScreen 上覆盖一个透明 panel，用户框选一个矩形后回调。
///
/// 坐标流：
///   mouseEvent.locationInWindow → view 本地坐标（左下原点，和 panel contentView 一致）
///   本地坐标 == window 坐标（因为 view 填满 window）
///   panel.convertToScreen(rect) → 全局屏幕坐标（和 NSScreen.frame 一致）
///   该 rect 直接交给 `CGDisplayCreateImageForRect`，不需要任何换算。
enum ScreenshotOverlayPresenter {
    private static var current: OverlayPanel?

    static func show(onCancel: @escaping () -> Void,
                     onCapture: @escaping (CGRect, NSScreen) -> Void) {
        hide()
        guard let screen = screenUnderMouse() ?? NSScreen.main else {
            onCancel()
            return
        }
        let panel = OverlayPanel(screen: screen)
        panel.onCancel = onCancel
        panel.onConfirm = { rect in onCapture(rect, screen) }
        panel.show()
        current = panel
    }

    static func hide() {
        current?.dismiss()
        current = nil
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}

// MARK: - Panel

private final class OverlayPanel {
    var onCancel: (() -> Void)?
    var onConfirm: ((CGRect) -> Void)?

    private let panel: NSPanel
    private let view: SelectionView
    private let screen: NSScreen

    init(screen: NSScreen) {
        self.screen = screen
        let frame = screen.frame
        self.panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.view = SelectionView(frame: NSRect(origin: .zero, size: frame.size))
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.contentView = view
        view.onCancel = { [weak self] in self?.dismiss(); self?.onCancel?() }
        view.onConfirm = { [weak self] localRect in
            guard let self = self else { return }
            let screenRect = self.panel.convertToScreen(localRect)
            self.dismiss()
            self.onConfirm?(screenRect)
        }
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        view.reset()
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

// MARK: - Selection View

private final class SelectionView: NSView {
    var onCancel: (() -> Void)?
    var onConfirm: ((CGRect) -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func reset() {
        startPoint = nil
        currentPoint = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 整屏半透明蒙层
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        guard let start = startPoint, let current = currentPoint else { return }
        let rect = normalize(start, current)

        // 选区"打洞"——用 clear + copy 把蒙层在该区域清掉
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        // 边框
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            currentPoint = nil
            needsDisplay = true
        }
        guard let start = startPoint, let current = currentPoint else { return }
        let rect = normalize(start, current)
        guard rect.width > 5, rect.height > 5 else {
            onCancel?()
            return
        }
        onConfirm?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
    }

    private func normalize(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
