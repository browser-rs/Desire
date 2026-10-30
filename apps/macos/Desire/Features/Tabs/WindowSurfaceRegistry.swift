import AppKit
import Foundation

/// 会话键 → 宿主 NSWindow 的弱注册表（v0.8.24）。
///
/// 为什么需要：`/diag/windows` 与 Peek 的"去处理"都要拿到某扇窗的 NSWindow，
/// 但新标签页没有挂载 webview（SwiftUI 直接渲染 NewTabPage），靠
/// `selectedTab.browser.webView.window` 会拿到 nil。这里由每个 ContentView
/// 的窗口标记视图在挂载时登记，弱引用不阻止关窗。
@MainActor
final class WindowSurfaceRegistry {
    static let shared = WindowSurfaceRegistry()

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow?) { self.window = window }
    }

    private var windows: [String: WeakWindow] = [:]

    private init() {}

    func register(_ window: NSWindow?, sessionKey: String?) {
        guard let sessionKey, !sessionKey.isEmpty else { return }
        windows[sessionKey] = WeakWindow(window)
    }

    func window(for sessionKey: String?) -> NSWindow? {
        guard let sessionKey else { return nil }
        return windows[sessionKey]?.window
    }
}
