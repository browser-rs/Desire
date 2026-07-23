import Combine
import WebKit

/// Blocks video ads across 8 streaming sites (YouTube, Bilibili, Tencent Video,
/// iQIYI, Youku, Mango TV, TikTok/Douyin, Twitter/X).
///
/// Two-layer strategy per site:
/// - **CSS** (`allCSS`): hides the static ad slot selectors via a single
///   `<style>` injected at document start, so the page never paints them.
/// - **JS** (`pageScript(for:)`): handles dynamic ads that are re-injected by
///   the SPA (YouTube Shorts ads, Bilibili live overlays, etc.) and clicks
///   "Skip Ad" buttons / seeks past pre-roll video ads.
///
/// Statistics are reported back to Swift via the
/// `window.webkit.messageHandlers.videoAdBlocked` message handler
/// (registered in `WebView.swift`'s `Coordinator`). The host shows a toast
/// like "已拦截 12 个视频广告".
@MainActor
class VideoAdBlocker: ObservableObject {
    @Published var isEnabled = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "videoAdBlockerEnabled")
        }
    }

    /// Cumulative number of ads removed on this tab lifetime. Reset by
    /// `resetCount()` when navigating to a new page.
    @Published var blockedCount: Int = 0

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "videoAdBlockerEnabled")
    }

    /// Reports that `n` more ads were just removed. Exposed as a method
    /// (not direct assignment) so JS-driven counts funnel through a single
    /// place for future throttling / debouncing.
    func reportBlocked(_ n: Int = 1) {
        blockedCount += n
    }

    /// Resets the per-navigation counter. Call from the WK navigation
    /// `didFinish` handler in `WebView.swift` alongside the pageScript call.
    func resetCount() {
        blockedCount = 0
    }

    // MARK: - Script entry points

    /// CSS injection script (always added at document start when enabled).
    /// Wraps the CSS in an IIFE that creates a single `<style id="desire-video-ad-css">`
    /// element. Re-runs are harmless (idempotent).
    func documentStartScript() -> WKUserScript {
        WKUserScript(source: Self.cssBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// JS injection script (added at document end when enabled). Wraps all
    /// per-site page scripts in a host-matching `if` so only the relevant
    /// site executes on each page. Non-video sites bail early (near-zero cost).
    func documentEndScript() -> WKUserScript {
        WKUserScript(source: Self.universalJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    /// Returns the per-site page script for `host`, or `nil` if the host
    /// isn't a supported video site or the blocker is disabled.
    /// Matching is done on `host.contains` so subdomains (e.g. `m.youtube.com`,
    /// `www.bilibili.com`) all work.
    func pageScript(for host: String) -> String? {
        guard isEnabled else { return nil }
        let h = host.lowercased()
        for site in VideoSite.allCases {
            if site.matches(h) {
                return site.pageScript
            }
        }
        return nil
    }

    // MARK: - CSS bootstrap

    private static let cssBootstrap: String = {
        let escaped = aggregateCSS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
            if (document.getElementById('desire-video-ad-css')) return;
            var s = document.createElement('style');
            s.id = 'desire-video-ad-css';
            s.textContent = '\(escaped)';
            (document.head || document.documentElement).appendChild(s);
        })();
        """
    }()

    /// Aggregated CSS from every registered `VideoSite`. Computed once at
    /// type-init time. Marked `static let` (not via `Self`) so it can be
    /// referenced from a stored property initializer below.
    private static let aggregateCSS: String = VideoSite.allCases
        .map { $0.css }
        .joined(separator: "\n")

    /// Universal JS that runs at `.atDocumentEnd`. Checks `location.hostname`
    /// against each site's host markers and runs only the matching site's page
    /// script. Non-video pages bail after the host-matching function definition.
    private static let universalJS: String = {
        var js = """
(function() {
    var __h = location.hostname.toLowerCase();
    function __m(arr) {
        for (var i = 0; i < arr.length; i++) { if (__h.indexOf(arr[i]) !== -1) return true; }
        return false;
    }

"""
        for site in VideoSite.allCases {
            let markers = site.hostMarkers.map { "'\($0)'" }.joined(separator: ",")
            js += """
    if (__m([\(markers)])) {
        \(site.pageScript)
    }

"""
        }
        js += """
})();
"""
        return js
    }()
}
