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
ytd-rich-item-renderer[is-ad], ytd-video-renderer[is-ad],
ytd-compact-video-renderer[is-ad], ytd-grid-video-renderer[is-ad],
yt-lockup-view-model[is-ad],
ytd-in-feed-ad-renderer,
ytd-ad-simple, #masthead-ad, yt-about-ad-renderer,
yt-mealbar-promo-renderer, ytp-ad-overlay-container, .video-ads,
ytd-unlimited-supply-renderer, ytd-merch-shelf-renderer,
ytd-search-panel-ad-renderer,
ytd-badge-supported-renderer, .badge-style-type-ad {
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
    var CARD = 'ytd-rich-item-renderer,ytd-video-renderer,ytd-compact-video-renderer,ytd-grid-video-renderer,yt-lockup-view-model';
    var AD_KEYWORDS = ['ad','ads','sponsored','promoted','推广','广告'];
    function hasAdText(el) {
        var t = el.textContent.toLowerCase();
        for (var i = 0; i < AD_KEYWORDS.length; i++) {
            if (t.indexOf(AD_KEYWORDS[i]) !== -1) {
                var badge = el.querySelector('.badge,.badge-style-type-ad,ytd-badge-supported-renderer');
                if (badge) return true;
            }
        }
        return false;
    }
    function removeAds() {
        document.querySelectorAll('ytd-ad-slot-renderer,ytd-display-ad-renderer,ytd-text-ad-renderer,ytd-compact-promoted-video-renderer,ytd-compact-promoted-item-renderer,ytd-promoted-sparkles-web-renderer,ytd-promoted-video-renderer,ytd-in-feed-ad-renderer,#masthead-ad,.video-ads,ytp-ad-overlay-container,ytd-ad-simple,yt-mealbar-promo-renderer,ytd-unlimited-supply-renderer,ytd-merch-shelf-renderer,ytd-search-panel-ad-renderer,ytd-badge-supported-renderer').forEach(function(el) { el.remove(); });
        document.querySelectorAll('[is-ad]').forEach(function(el) { var c = el.closest(CARD); (c||el).remove(); });
        document.querySelectorAll('.badge-style-type-ad').forEach(function(el) { var c = el.closest(CARD); if (c) c.remove(); });
        document.querySelectorAll(CARD).forEach(function(el) { if (hasAdText(el)) el.remove(); });
    }
    function skipVideoAd() {
        var skip = document.querySelector('.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-ad-skip-button-container button,.ytp-ad-skip-button-slot');
        if (skip) { skip.click(); return; }
        document.querySelectorAll('button,.ytp-button').forEach(function(b) {
            var t = (b.textContent||'').trim().toLowerCase();
            var a = (b.getAttribute('aria-label')||'').toLowerCase();
            if (t==='skip'||t.indexOf('skip ad')===0||a.indexOf('skip')===0) b.click();
        });
        var player = document.querySelector('.ad-showing video,.ad-interrupting video');
        if (player && player.duration > 0 && player.currentTime < player.duration - 0.5) {
            player.currentTime = player.duration - 0.3;
        }
    }
    function closeOverlay() {
        var c = document.querySelector('.ytp-ad-overlay-close-button');
        if (c) c.click();
    }
    function dismissPromo() {
        var d = document.querySelector('yt-mealbar-promo-renderer .dismiss-button,ytd-popup-container yt-button-renderer,.yt-spec-button-shape-next--overlay');
        if (d) d.click();
    }
    var obs = new MutationObserver(function() { removeAds(); skipVideoAd(); closeOverlay(); dismissPromo(); });
    if (document.body) obs.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['is-ad','class'] });
    var delays = [100,300,700,1200,2000,3500,5000,8000];
    for (var i=0;i<delays.length;i++) (function(t){setTimeout(function(){removeAds();skipVideoAd();},t)})(delays[i]);
    var n=0,poll=setInterval(function(){removeAds();skipVideoAd();if(++n>60)clearInterval(poll)},2500);
})();
"""

    private static let bilibiliJS = """
(function() {
    var sel = '.bpx-player-video-ad,.bpx-player-ad,.bili-video-ad,.ad-report,.ad-container';
    var obs = new MutationObserver(function() {
        document.querySelectorAll(sel).forEach(function(el) { el.style.display = 'none'; });
        var w = document.querySelector('.bpx-player-video-wrap video');
        if (w) { var a = w.closest('.bpx-player-video-ad'); if (a) a.style.display = 'none'; }
    });
    if (document.body) obs.observe(document.body, { childList: true, subtree: true });
    setTimeout(function() { obs.takeRecords(); }, 200);
    setTimeout(function() { obs.takeRecords(); }, 1000);
})();
"""
}
