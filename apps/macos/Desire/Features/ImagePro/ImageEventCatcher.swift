import AppKit
import SwiftUI

/// 画布事件捕获层（v0.8.45 专业批 2）：参考 SSX 截图软件的 NSView 直驱模式——
/// 鼠标事件在 **NSView bounds 坐标系**（isFlipped，左上原点，y 向下）里回调，
/// 参考系唯一且明确。此前用 SwiftUI DragGesture 且挂在容器层，location 的
/// 参考系随挂载层级漂移（y 恒多画布上方 UI 高度），标记/裁剪全部错位。
///
/// 事件语义：
/// - down/dragged/up：工具绘制（坐标 = 容器 bounds）
/// - moved/exited：hover（笔刷光标）
/// - magnify(delta, anchor)：捏合缩放（anchor = 事件位置）
/// - scroll(delta, anchor, command)：⌘ 滚 = 缩放，普通滚 = 平移
/// - doubleClick(anchor)：双击
struct ImageEventCatcher: NSViewRepresentable {
    enum Kind {
        case down, dragged, up, moved, exited
    }

    var onPoint: (Kind, CGPoint, NSEvent.ModifierFlags) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onScroll: (CGFloat, CGFloat, CGPoint, Bool) -> Void
    var onDoubleClick: (CGPoint) -> Void
    var onSizeChange: (CGSize) -> Void
    /// 单键快捷键（工具切换/裁剪/取消）：NSView 是第一响应者，键直接到这里，
    /// 不依赖 SwiftUI keyboardShortcut 在所有窗口状态下的解析（实测单键 C
    /// 偶尔被吞）。返回 true = 已消费。
    var onKey: (String) -> Bool = { _ in false }

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onPoint = onPoint
        view.onMagnify = onMagnify
        view.onScroll = onScroll
        view.onDoubleClick = onDoubleClick
        view.onSizeChange = onSizeChange
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.onPoint = onPoint
        view.onMagnify = onMagnify
        view.onScroll = onScroll
        view.onDoubleClick = onDoubleClick
        view.onSizeChange = onSizeChange
        view.onKey = onKey
        context.coordinator.parent = self
        if view.bounds.size != context.coordinator.lastSize {
            context.coordinator.lastSize = view.bounds.size
            onSizeChange(view.bounds.size)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var parent: ImageEventCatcher?
        var lastSize: CGSize = .zero
    }

    final class EventView: NSView {
        /// 当前画布事件层（文字输入结束后把焦点还给它）。
        static weak var active: EventView?
        var onPoint: ((Kind, CGPoint, NSEvent.ModifierFlags) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onScroll: ((CGFloat, CGFloat, CGPoint, Bool) -> Void)?
        var onDoubleClick: ((CGPoint) -> Void)?
        var onSizeChange: ((CGSize) -> Void)?
        var onKey: ((String) -> Bool)?
        /// 上次上报的尺寸：`layout()` 每轮布局都会跑，无条件上报会让
        /// SwiftUI 侧把"重算 fit"（= 居中归零 pan）当成尺寸变化来执行——
        /// 拖动平移时每帧把 pan 打回零，用户看到"抖、一直在找中心"。
        private var lastNotifiedSize: CGSize = .zero

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                let area = NSTrackingArea(
                    rect: NSRect(origin: .zero, size: bounds.size),
                    options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                    owner: self)
                addTrackingArea(area)
                // 打开图片后直接可用的单键快捷键：不自取焦点的话必须先在
                // 画布上点一下（合成事件也不走窗口级 monitor，实测）。
                Self.active = self
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    // 挂载即夺焦：否则"打开图片后按 B/C 无效"，必须先点画布。
                    window.makeFirstResponder(self)
                }
            }
        }

        override func layout() {
            super.layout()
            #if DEBUG
            // 事件层在窗口坐标里的精确矩形（左下原点）——桥测试把
            // "容器坐标 ↔ 窗口合成事件坐标"的换算锚在实测值上，不再猜
            // 工具栏/标题栏高度（此前 +22pt 系统性偏移的根源）。
            let rect = convert(bounds, to: nil)
            ImageEditorDebug.lastStamp["catcherRectX"] = Double(rect.minX)
            ImageEditorDebug.lastStamp["catcherRectY"] = Double(rect.minY)
            ImageEditorDebug.lastStamp["catcherRectW"] = Double(rect.width)
            ImageEditorDebug.lastStamp["catcherRectH"] = Double(rect.height)
            #endif
            let size = bounds.size
            guard size != lastNotifiedSize else { return }
            lastNotifiedSize = size
            onSizeChange?(size)
        }

        private func location(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        /// ⌘⏎ 会被窗口的 key-equivalent 扫描先截走（SwiftUI 按钮快捷键在
        /// NSView 当第一响应者时不生效）——这里直接认领，交回编辑器。
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "\r" {
                return onKey?("\r") ?? false
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            // 带 ⌘/⌃/⌥ 的组合交给系统（菜单快捷键走 performKeyEquivalent）；
            // 例外：⌘⏎ 是编辑器自己的"应用裁剪"（SwiftUI 按钮快捷键在
            // 合成事件/部分焦点状态下不生效，这里直收）。
            let blockers: NSEvent.ModifierFlags = [.command, .control, .option]
            let chars = event.charactersIgnoringModifiers
            #if DEBUG
            ImageEditorDebug.lastStamp["evtKey"] = chars ?? "<nil>"
            ImageEditorDebug.lastStamp["evtKeyMods"] = Int(event.modifierFlags.rawValue)
            ImageEditorDebug.lastStamp["evtKeyIsFR"] =
                (window?.firstResponder === self)
            #endif
            let commandReturn = event.modifierFlags.contains(.command) && chars == "\r"
            if (event.modifierFlags.intersection(blockers).isEmpty || commandReturn),
               let chars,
               onKey?(chars.lowercased()) == true {
                return
            }
            super.keyDown(with: event)
        }

        #if DEBUG
        private var downCount = 0
        private var dragCount = 0
        private var upCount = 0
        private func noteEvent(_ kind: String, _ p: CGPoint) {
            ImageEditorDebug.lastStamp["evt" + kind + "X"] = Double(p.x)
            ImageEditorDebug.lastStamp["evt" + kind + "Y"] = Double(p.y)
        }
        #endif

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            #if DEBUG
            downCount += 1
            ImageEditorDebug.lastStamp["evtDownCount"] = downCount
            noteEvent("Down", location(event))
            #endif
            onPoint?(.down, location(event), event.modifierFlags)
        }

        override func mouseDragged(with event: NSEvent) {
            #if DEBUG
            dragCount += 1
            ImageEditorDebug.lastStamp["evtDragCount"] = dragCount
            noteEvent("Drag", location(event))
            #endif
            onPoint?(.dragged, location(event), event.modifierFlags)
        }

        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?(location(event))
                return
            }
            #if DEBUG
            upCount += 1
            ImageEditorDebug.lastStamp["evtUpCount"] = upCount
            noteEvent("Up", location(event))
            #endif
            onPoint?(.up, location(event), event.modifierFlags)
        }

        override func mouseMoved(with event: NSEvent) {
            onPoint?(.moved, location(event), event.modifierFlags)
        }

        override func mouseExited(with event: NSEvent) {
            onPoint?(.exited, location(event), event.modifierFlags)
        }

        override func magnify(with event: NSEvent) {
            onMagnify?(event.magnification, location(event))
        }

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY,
                      location(event),
                      event.modifierFlags.contains(.command))
        }
    }
}
