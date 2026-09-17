import Foundation
import WebKit

/// Central entry point for entering/leaving responsive emulation.
///
/// A device viewport alone does NOT make sites serve their mobile layout —
/// most sites gate on the USER AGENT. Entering responsive mode therefore
/// swaps in a real iOS Safari UA (iPhone for phone-width viewports, iPad
/// for tablet-width) and RELOADS the page (UA only applies to fresh
/// loads). Exiting restores the desktop UA and reloads again.
@MainActor
enum ResponsiveModeApplier {
    private static let iphoneUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    private static let ipadUA =
        "Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    static func apply(_ enabled: Bool, to tab: Tab) {
        let webView = tab.browser.webView
        if enabled {
            webView.customUserAgent = userAgent(forViewportWidth: tab.responsiveConfig.effectiveSize.width)
            webView.reload()
            if tab.responsiveConfig.touchSimulationEnabled {
                TouchSimulation.apply(to: webView)
            }
        } else {
            webView.customUserAgent = nil   // back to the desktop Safari UA
            TouchSimulation.remove(from: webView)
            webView.reload()
        }
    }

    /// Device-class UA for the current viewport width. Keeps the desktop UA
    /// for desktop-class widths (no point pretending to be a phone).
    static func userAgent(forViewportWidth width: CGFloat) -> String {
        if width < 500 { return iphoneUA }
        if width < 1200 { return ipadUA }
        return BrowserState._desktopSafariUA
    }
}
