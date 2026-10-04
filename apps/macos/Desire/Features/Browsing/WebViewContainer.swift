import AppKit
import WebKit

/// SwiftUI host for a tab's `WKWebView`.
///
/// The `WebView` representable returns THIS view instead of the web view
/// itself, and that indirection is load-bearing for video fullscreen:
///
/// SwiftUI lays out the view an `NSViewRepresentable` returns on every layout
/// pass — and it keeps doing so while that view is not in the tree anymore.
/// Element fullscreen is exactly that case: WebKit moves the web view into its
/// own full-screen window (`WebCoreFullScreenWindow`) and sizes it to that
/// window. Measured on-device with the web view as the representable's view,
/// the frame went
///     2560×1262 (tab area) → 2560×1440 (WebKit's fullscreen frame)
///   → 2560×1262 (SwiftUI re-applying the tab-area size)
///   → 0×0       (SwiftUI laying out the now-collapsed pane),
/// so the fullscreen video was letterboxed inside a stale viewport (黑边) or
/// the page rendered at 0×0 (黑屏). With a plain container as the
/// representable's view, SwiftUI only ever sizes the container: the web view
/// follows it through its autoresizing mask while it lives here, and once
/// WebKit swaps it into the fullscreen window — leaving a placeholder in this
/// container that inherits both frame and mask — nothing in the app writes the
/// web view's frame again.
final class WebViewContainer: NSView {
    let webView: BrowserWKWebView

    init(webView: BrowserWKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        // Frame-based on purpose: the autoresizing mask is what keeps the web
        // view (and WebKit's fullscreen placeholder) filling this container.
        // SwiftUI's Auto Layout must never own the web view itself.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Keep the web view filling the container. While WebKit has the web view
    /// in its fullscreen window it is no longer our subview, so this is
    /// skipped — which is the whole point: fullscreen geometry belongs to
    /// WebKit until the web view comes back.
    override func layout() {
        super.layout()
        if webView.superview === self, webView.frame != bounds {
            webView.frame = bounds
        }
    }
}
