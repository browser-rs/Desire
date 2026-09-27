import AppKit

/// 批量下载遇到**交互式人机验证**（Cloudflare Turnstile 等）时，把隐藏解析
/// 器的 webview 提到一个小窗里让用户亲手完成验证。
///
/// 窗口只是"展示载体"：验证解除的判定由批量引擎轮询
/// `HeadlessMediaResolver.refreshChallengeState()` 完成（挑战 iframe 消失 /
/// 页面自行跳转），与窗口本身无关——用户点掉红绿灯关掉窗口也不会中断
/// 等待，引擎检测到解除后照常续跑。多条批次共用这一个窗口（同一时刻至
/// 多一条批次处于 needsHuman）。
@MainActor
final class BatchVerifyWindowController: NSObject, NSWindowDelegate {
    static let shared = BatchVerifyWindowController()

    private var window: NSWindow?
    /// 当前展示在窗口里的 webview（归属 HeadlessMediaResolver）。
    private var hostedWebView: NSView?

    /// 把解析器的 webview 装进小窗并前置。
    func present(webView: NSView) {
        let window = self.window ?? makeWindow()
        self.window = window
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        if let hosted = hostedWebView, hosted !== webView {
            hosted.removeFromSuperview()
        }
        hostedWebView = webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            webView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        ])
        window.title = String(localized: "Human verification required")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 批次结束（或取消）后收起窗口、归还 webview 的展示权。
    func dismiss() {
        window?.orderOut(nil)
    }

    // MARK: - 窗口

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        return window
    }

    /// 红绿灯关闭 = 收起窗口，**不**取消等待（引擎在轮询挑战状态，
    /// 解除后自动继续；重新展示会复用这个窗口）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
