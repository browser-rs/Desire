import AppKit
import Combine
import os
import WebKit

/// 鼠标手势 / 超级拖拽（0.7.13，Backlog 提前）：
/// - **手势**：按住右键拖动画轨迹，松手按轨迹方向执行动作（默认关）。
///   右键默认弹上下文菜单——手势开启时改为"按住不放拖动 = 手势，原地点击 = 菜单"。
/// - **超级拖拽**：拖动链接到页面空白处松开 = 新后台标签打开（默认关）。
/// 两者都走 NSEvent 本地监视器（与 TabMiddleClickMonitor 同款），只处理自家
/// webview 窗口内的事件；设置持久化在 UserDefaults。
@MainActor
final class MouseGestureStore: ObservableObject {
    static let shared = MouseGestureStore()

    /// 鼠标手势开关（右键拖动）。
    @Published var gestureEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gestureEnabled, forKey: "mouseGesture.enabled")
            rebuildMonitors()
        }
    }

    /// 超级拖拽开关（拖链接到页面空白 = 新后台标签）。
    @Published var superDragEnabled: Bool {
        didSet {
            UserDefaults.standard.set(superDragEnabled, forKey: "superDrag.enabled")
            rebuildMonitors()
        }
    }

    private var gestureMonitor: Any?
    private var dragMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        gestureEnabled = UserDefaults.standard.object(forKey: "mouseGesture.enabled") as? Bool ?? false
        superDragEnabled = UserDefaults.standard.object(forKey: "superDrag.enabled") as? Bool ?? false
        rebuildMonitors()
    }

    // MARK: - 手势状态机

    /// 手势轨迹采样：右键 down 开始，移动超阈值后记录方向序列，up 时解析。
    private var gestureActive = false
    private var gestureStart: NSPoint = .zero
    private var gestureDirections: [Character] = []   // u/d/l/r
    private var lastSample: NSPoint = .zero
    /// 轨迹解析用：上一次方向切换的采样点。
    private var segmentAnchor: NSPoint = .zero
    private static let segmentThreshold: CGFloat = 30   // 单段最小位移

    // MARK: - 超级拖拽状态

    private var dragStartedInsideLink = false
    private var dragLinkURL: String?
    private var dragStartPoint: NSPoint = .zero

    // MARK: - Monitors

    private func rebuildMonitors() {
        if let m = gestureMonitor { NSEvent.removeMonitor(m); gestureMonitor = nil }
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        if gestureEnabled {
            gestureMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .rightMouseUp, .rightMouseDragged]
            ) { [weak self] event in
                self?.handleGestureEvent(event)
                return event
            }
        }
        if superDragEnabled {
            dragMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .leftMouseDragged]
            ) { [weak self] event in
                self?.handleSuperDragEvent(event)
                return event
            }
        }
    }

    // MARK: - 手势事件处理

    private func handleGestureEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            gestureActive = true
            gestureStart = event.locationInWindow
            lastSample = gestureStart
            segmentAnchor = gestureStart
            gestureDirections = []

        case .rightMouseDragged where gestureActive:
            let pt = event.locationInWindow
            let dx = pt.x - segmentAnchor.x
            let dy = pt.y - segmentAnchor.y
            if abs(dx) >= Self.segmentThreshold || abs(dy) >= Self.segmentThreshold {
                let dir: Character = abs(dx) > abs(dy) ? (dx > 0 ? "r" : "l") : (dy > 0 ? "u" : "d")
                if gestureDirections.last != dir { gestureDirections.append(dir) }
                segmentAnchor = pt
            }
            lastSample = pt

        case .rightMouseUp where gestureActive:
            gestureActive = false
            let pt = event.locationInWindow
            let moved = hypot(pt.x - gestureStart.x, pt.y - gestureStart.y)
            guard moved > Self.segmentThreshold, !gestureDirections.isEmpty else { return } // 原地点击 = 菜单
            let trail = String(gestureDirections)
            dispatchGesture(trail, in: event.window)

        default:
            break
        }
    }

    /// 手势动作分发（在主线程；动作经 BrowsingActions 的既有命令通道）。
    /// 轨迹→动作映射抽到 `MouseGestureTrail`（纯逻辑进单测）。
    private func dispatchGesture(_ trail: String, in window: NSWindow?) {
        guard let tm = TabSessionCoordinator.shared.activeTabManager else { return }
        guard let action = MouseGestureTrail.action(for: trail) else { return }
        Log.app.info("mouse gesture: \(trail, privacy: .public) → \(action, privacy: .public)")
        let tab = tm.selectedTab
        switch action {
        case "back": tab?.browser.webView.goBack()
        case "forward": tab?.browser.webView.goForward()
        case "reload": tab?.browser.webView.reload()
        case "new-tab": tm.addTab()
        case "close-tab": if let tab { tm.closeTab(at: (tm.tabs as NSArray).index(of: tab)) }
        default: break
        }
        _ = window
    }

    // MARK: - 超级拖拽

    private var superDragMoved = false

    /// 链接上按下 → 拖动（leftMouseDragged 任意移动标记）→ 松手开后台标签。
    /// 距离判定用 moved 标记而非坐标差（JS screen 坐标与窗口坐标不同框）。
    private func handleSuperDragEvent(_ event: NSEvent) {
        if event.type == .leftMouseDragged, dragStartedInsideLink {
            let pt = event.locationInWindow
            if hypot(pt.x - dragStartPoint.x, pt.y - dragStartPoint.y) > 10 { superDragMoved = true }
            dragStartPoint = pt   // 窗口坐标系内比较（起点用首个 dragged 事件坐标）
            return
        }
        guard event.type == .leftMouseUp, dragStartedInsideLink else { return }
        defer {
            dragStartedInsideLink = false
            dragLinkURL = nil
            superDragMoved = false
        }
        guard superDragMoved, let urlString = dragLinkURL else { return }
        guard let tm = TabSessionCoordinator.shared.activeTabManager else { return }
        tm.addTab(url: urlString, makeActive: false)
        Log.app.info("super drag: opened \(urlString, privacy: .public) in background tab")
    }

    /// webview 侧在链接上按下时调用（super-drag.js 经消息通道）。
    func noteLinkDragStart(urlString: String, at point: NSPoint) {
        dragStartedInsideLink = true
        dragLinkURL = urlString
        dragStartPoint = point
    }

    func noteNonLinkDragStart() {
        dragStartedInsideLink = false
        dragLinkURL = nil
    }
}
