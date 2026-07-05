import Combine
import WebKit

@MainActor
class VideoAdBlocker: ObservableObject {
    @Published var isEnabled = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "videoAdBlockerEnabled")
        }
    }

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "videoAdBlockerEnabled")
    }

    func documentStartScript() -> WKUserScript {
        WKUserScript(source: Self.cssScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    func pageScript(for host: String) -> String? {
        guard isEnabled else { return nil }
        let h = host.lowercased()
        if h.contains("youtube.com") { return Self.youtubeJS }
        if h.contains("bilibili.com") { return Self.bilibiliJS }
        return nil
    }

    private static let cssScript: String = {
        let css = VideoAdBlocker.allCSS
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
            var s = document.createElement('style');
            s.id = 'desire-video-ad-css';
            s.textContent = '\(escaped)';
            document.documentElement.appendChild(s);
        })();
        """
    }()

    private static let youtubeCSS = """
ytd-ad-slot-renderer, ytd-display-ad-renderer, ytd-text-ad-renderer,
ytd-compact-promoted-video-renderer, ytd-compact-promoted-item-renderer,
ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer,
ytd-rich-item-renderer[is-ad], ytd-in-feed-ad-renderer,
ytd-ad-simple, #masthead-ad, yt-about-ad-renderer,
yt-mealbar-promo-renderer, ytp-ad-overlay-container, .video-ads,
ytd-ad-slot-renderer[is-ad],
ytd-unlimited-supply-renderer, ytd-merch-shelf-renderer,
ytd-search-panel-ad-renderer, yt-about-ad-renderer {
    display: none !important;
}
"""

    private static let bilibiliCSS = """
.bpx-player-video-ad, .bpx-player-ad, .bpx-player-video-ad-container,
.bpx-ad-container, .bpx-ad-block,
.ad-report, .ad-container, .ad-area, .banner-ad-container,
.recommend-ad, .video-page-ad, .ad-card,
.ad-report, .ad-banner, .floor-ad,
#ad_bottom, #ad_top, #ad_left, #ad_right,
.side-ad, .top-ad, .feed-ad,
.bili-video-ad {
    display: none !important;
}
"""

    private static var allCSS: String {
        [youtubeCSS, bilibiliCSS].joined(separator: "\n")
    }

    private static let youtubeJS = """
(function() {
    function removeAds() {
        document.querySelectorAll([
            'ytd-ad-slot-renderer', 'ytd-display-ad-renderer', 'ytd-text-ad-renderer',
            'ytd-compact-promoted-video-renderer', 'ytd-rich-item-renderer[is-ad]',
            'ytd-in-feed-ad-renderer', '#masthead-ad', '.video-ads',
            'ytp-ad-overlay-container', 'ytd-ad-simple', 'yt-mealbar-promo-renderer',
            'ytd-unlimited-supply-renderer', 'ytd-merch-shelf-renderer'
        ].join(',')).forEach(function(el) { el.remove(); });
    }
    function skipVideoAd() {
        var skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-container button');
        if (skip) { skip.click(); return; }
        var video = document.querySelector('.ad-showing video, .ad-interrupting video');
        if (video && video.duration > 0 && video.currentTime < video.duration - 0.5) {
            video.currentTime = video.duration - 0.5;
        }
    }
    function closeOverlay() {
        var close = document.querySelector('.ytp-ad-overlay-close-button');
        if (close) close.click();
    }
    function dismissPromo() {
        var dismiss = document.querySelector('yt-mealbar-promo-renderer .dismiss-button, ytd-popup-container yt-button-renderer');
        if (dismiss) dismiss.click();
    }
    var observer = new MutationObserver(function() {
        removeAds();
        skipVideoAd();
        closeOverlay();
        dismissPromo();
    });
    if (document.body) observer.observe(document.body, { childList: true, subtree: true });
    setTimeout(function() { removeAds(); skipVideoAd(); closeOverlay(); }, 100);
    setTimeout(function() { removeAds(); skipVideoAd(); }, 500);
    setTimeout(function() { removeAds(); }, 1500);
})();
"""

    private static let bilibiliJS = """
(function() {
    var observer = new MutationObserver(function() {
        document.querySelectorAll('.bpx-player-video-ad, .bpx-player-ad, .ad-report, .ad-container, .bili-video-ad').forEach(function(el) {
            el.style.display = 'none';
        });
        var video = document.querySelector('.bpx-player-video-wrap video');
        if (video) {
            var adWrap = video.closest('.bpx-player-video-ad');
            if (adWrap) { adWrap.style.display = 'none'; }
        }
    });
    if (document.body) observer.observe(document.body, { childList: true, subtree: true });
    setTimeout(function() { observer.takeRecords(); }, 200);
    setTimeout(function() { observer.takeRecords(); }, 1000);
})();
"""
}
