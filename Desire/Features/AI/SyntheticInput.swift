import AppKit
import WebKit

/// Dispatches real (`isTrusted == true`) mouse events into a WKWebView.
///
/// Why this exists: `element.click()` and hand-built `MouseEvent`s are
/// synthesized *inside* the web process, so the page sees them with
/// `isTrusted == false`. Anti-automation systems — Cloudflare Turnstile in
/// particular — treat untrusted interaction as a bot signal and will
/// challenge or block the user's session. The only trusted input path into
/// WKWebView is a genuine NSEvent routed through the AppKit event pipeline
/// (`NSApp.sendEvent` → `NSWindow.sendEvent` → WKWebView → WebKit), which
/// is indistinguishable from a physical mouse.
///
/// In-process dispatch needs no Accessibility permission and works even when
/// the app is not frontmost. Agent tools call this with the center point of
/// a resolved element (see `BrowserToolProvider.clickablePoint`); the in-page
/// `__desireClick`/`__desireHover` JS remains the fallback for webviews with
/// no window (suspended/background tabs).
@MainActor
enum SyntheticInput {
    /// Posts a mouse-down/up pair at `point` (window-base coordinates,
    /// bottom-left origin — what `NSEvent.mouseEvent(location:)` expects).
    static func click(at point: CGPoint, in webView: WKWebView) async {
        guard let window = webView.window else { return }
        post(.leftMouseDown, at: point, windowNumber: window.windowNumber, clickCount: 1)
        // A short gap so WebKit sees down and up as separate user actions
        // (instant tap counts as a click, but some sites measure hold time).
        try? await Task.sleep(nanoseconds: 40_000_000)
        post(.leftMouseUp, at: point, windowNumber: window.windowNumber, clickCount: 1)
    }

    /// Posts a short stream of mouse-moved events approaching and ending at
    /// `point`, so the page sees a cursor entering the element — that is
    /// what makes `:hover` CSS and mouseover/mouseenter fire.
    static func hover(at point: CGPoint, in webView: WKWebView) async {
        guard let window = webView.window else { return }
        // WebKit only forwards moved events when the window opts in.
        // Browsers leave this enabled; the default NSWindow opt-out exists
        // for document windows that never need hover.
        window.acceptsMouseMovedEvents = true
        let start = CGPoint(x: point.x - 24, y: point.y - 18)
        for step in 0...2 {
            let t = CGFloat(step) / 2
            let p = CGPoint(x: start.x + (point.x - start.x) * t,
                            y: start.y + (point.y - start.y) * t)
            post(.mouseMoved, at: p, windowNumber: window.windowNumber, clickCount: 0)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func post(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int, clickCount: Int) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1.0 : 0.0
        ) else { return }
        NSApp.sendEvent(event)
    }
}
