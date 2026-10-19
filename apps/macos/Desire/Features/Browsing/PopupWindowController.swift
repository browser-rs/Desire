import AppKit
import WebKit

/// OAuth/SSO 弹窗（v0.7.25）：`window.open` 必须开**真弹窗**而不是转成标签——
/// 回跳页靠 `window.opener.postMessage` 把授权码交回原页。crates.io 的
/// "Login with GitHub" 实测：转标签 = opener 为 null = 登录永远完不成
/// （回跳页静默什么都不做）。
///
/// 做法：用 WebKit 在 `createWebViewWith` 里交给我们的 `configuration` 创建
/// WKWebView 并放进独立窗口——这样 WebKit 会自动接好 opener 关系，cookie/
/// 进程池也沿用外层的。页面调用 `window.close()` 时经 `webViewDidClose` 关窗。
@MainActor
final class PopupWindowController: NSObject, WKUIDelegate, NSWindowDelegate {
    /// 弱注册表：窗口自己持有内容，这里只防控制器提前释放。
    private static var live: [ObjectIdentifier: PopupWindowController] = [:]

    let window: NSWindow
    let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?

    private init(window: NSWindow, webView: WKWebView) {
        self.window = window
        self.webView = webView
        super.init()
    }

    /// 为一次 `window.open` 建窗并显示；返回的 webview 必须原样交给 WebKit。
    /// 尺寸取 windowFeatures（缺省 800×620，下限 360×320——授权页有按钮）。
    static func present(configuration: WKWebViewConfiguration,
                        features: WKWindowFeatures) -> WKWebView {
        let width = max(360, features.width?.doubleValue ?? 800)
        let height = max(320, features.height?.doubleValue ?? 620)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let webView = WKWebView(frame: rect, configuration: configuration)
        let window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Sign in")
        window.contentView = webView
        window.isReleasedWhenClosed = false
        let controller = PopupWindowController(window: window, webView: webView)
        webView.uiDelegate = controller
        window.delegate = controller
        live[ObjectIdentifier(controller)] = controller
        controller.titleObservation = webView.observe(\.title, options: [.new]) { [weak controller] webView, _ in
            let title = webView.title ?? ""
            DispatchQueue.main.async {
                guard let window = controller?.window, !title.isEmpty else { return }
                window.title = title
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        return webView
    }

    /// 页面里的 `window.close()`。
    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        PopupWindowController.live.removeValue(forKey: ObjectIdentifier(self))
        titleObservation?.invalidate()
        titleObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}
