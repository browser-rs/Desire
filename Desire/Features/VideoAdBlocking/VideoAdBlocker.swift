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
    /// `private(set)`: the only writer is `setEnabled(_:)`, so every off-switch
    /// is an explicit user choice (see `init` for why that distinction exists).
    @Published private(set) var isEnabled = true

    /// Set once the user has flipped the Settings switch themselves. Until
    /// then the stored value is not authoritative: before 4d67f1e the
    /// initializer read the unset UserDefaults bool and wrote `false` back on
    /// first launch, so installs from that era carry an "off" that no user ever
    /// chose (it silently kept the blocker dead long after the bug was fixed).
    private static let userChoiceKey = "videoAdBlockerUserSet"
    private static let enabledKey = "videoAdBlockerEnabled"

    /// Cumulative number of ads removed on this tab lifetime. Reset by
    /// `resetCount()` when navigating to a new page.
    @Published var blockedCount: Int = 0

    init() {
        let defaults = UserDefaults.standard
        isEnabled = Self.resolvedEnabled
        if !defaults.bool(forKey: Self.userChoiceKey) {
            // No explicit choice on record → the legacy `false` (from the
            // first-launch bug) is overwritten with the declared default, so
            // the blocker can't stay dead forever on an old install.
            defaults.set(true, forKey: Self.enabledKey)
        }
    }

    /// The value the setting actually means: without a recorded user choice
    /// it is the declared default (ON), regardless of what an old build left
    /// in UserDefaults. Single source of truth for `init` and the bridge's
    /// `GET /settings`.
    static var resolvedEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: userChoiceKey) else { return true }
        return defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Settings switch entry point — records the choice as explicit.
    func setEnabled(_ enabled: Bool) {
        let defaults = UserDefaults.standard
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(true, forKey: Self.userChoiceKey)
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
    ///
    /// The CSS comes from `VideoAdRulesStore` at call time (per new webview), so
    /// a rule change is a file/edit + reload — not a rebuild. See that type for
    /// the local-override / remote-bundle / built-in precedence.
    func documentStartScript() -> WKUserScript {
        WKUserScript(
            source: VideoAdRulesStore.shared.cssInstallScript(replaceStale: false),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// JS injection script (added at document end when enabled). Wraps all
    /// per-site page scripts in a host-matching `if` so only the relevant
    /// site executes on each page. Non-video sites bail early (near-zero cost).
    /// Rules resolved through `VideoAdRulesStore` (see `documentStartScript`).
    func documentEndScript() -> WKUserScript {
        WKUserScript(
            source: Self.universalJS(store: VideoAdRulesStore.shared),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    /// 导航时（`didFinish`）按"当前规则"重投一次页面脚本：user script 是
    /// webview 创建时定格的，规则改动后只有这条路能把新规则送进已打开的标签
    /// （外层代数包装器决定是否需要重跑，见 `VideoAdRulesStore`）。
    func pageScript(for host: String) -> String? {
        guard isEnabled else { return nil }
        return VideoAdRulesStore.shared.pageJSScript(for: host)
    }

    // MARK: - CSS bootstrap

    /// Universal JS that runs at `.atDocumentEnd`. Checks `location.hostname`
    /// against each site's host markers and runs only the matching site's page
    /// script. Non-video pages bail after the host-matching function definition.
    private static func universalJS(store: VideoAdRulesStore) -> String {
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
        \(store.pageJSScript(for: site))
    }

"""
        }
        js += """
})();
"""
        return js
    }
}
