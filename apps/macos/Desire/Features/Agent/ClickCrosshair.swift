import AppKit
import Foundation
import SwiftUI

/// clickAt 落点准星（v0.8.56 批 1）：派发真实鼠标事件前，在屏幕坐标处闪一圈
/// 准星环（~0.6s）——用户看得见 Agent 要点哪（与 DOM `highlight` 的橙框同一
/// 可见性哲学；诊断截图也能拍到）。非激活、不吃事件、不抢空间的全透明浮层。
@MainActor
enum ClickCrosshair {

    static let visibleDuration: TimeInterval = 0.6

    /// `windowPoint` 为窗口 base 坐标（`windowPoint(fromViewportX:y:in:)` 的输出）。
    static func flash(at windowPoint: CGPoint, in view: NSView) {
        guard let window = view.window else { return }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let size: CGFloat = 44
        let panel = CrosshairPanel(
            contentRect: CGRect(x: screenPoint.x - size / 2,
                                y: screenPoint.y - size / 2,
                                width: size, height: size))
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration) { [weak panel] in
            panel?.orderOut(nil)
            panel?.close()
        }
    }
}

/// 全透明边框浮层：画一圈强调色描边环 + 十字线（AppAccent.current——
/// AppKit 侧无 environment，读 Settings didSet 维护的静态当前值）。
@MainActor
final class CrosshairPanel: NSPanel {

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        worksWhenModal = true
        hasShadow = false
        contentView = CrosshairView(frame: NSRect(origin: .zero,
                                                   size: contentRect.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CrosshairView: NSView {

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor(AppAccent.current)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 13

        // 十字线（两端留出环内空隙）
        let cross: CGFloat = bounds.width / 2 - 3
        let gap: CGFloat = 4
        accent.setStroke()
        let crossPath = NSBezierPath()
        crossPath.lineWidth = 1.5
        for (dx, dy) in [(CGFloat(1), CGFloat(0)), (CGFloat(-1), CGFloat(0)),
                         (CGFloat(0), CGFloat(1)), (CGFloat(0), CGFloat(-1))] {
            crossPath.move(to: CGPoint(x: center.x + dx * gap, y: center.y + dy * gap))
            crossPath.line(to: CGPoint(x: center.x + dx * cross, y: center.y + dy * cross))
        }
        crossPath.stroke()

        // 准星环
        context.saveGState()
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        ring.lineWidth = 2.5
        accent.setStroke()
        ring.stroke()
        context.restoreGState()

        // 中心点
        accent.setFill()
        NSBezierPath(rect: CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)).fill()
    }
}
