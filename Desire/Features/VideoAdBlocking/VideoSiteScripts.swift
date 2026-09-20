import Foundation

/// Per-site video-ad-blocking configuration extracted from `VideoAdBlocker`:
/// the `VideoSite` registry plus the CSS and page-level JS for each supported
/// site (~830 lines of rules/scripts). Kept in its own file so the Store
/// class stays focused on state + WKUserScript composition. `VideoAdBlocker`
/// reads `VideoSite.allCases`, `.hostMarkers`, `.css`, and `.pageScript`.

// MARK: - Site registry

/// Per-site configuration: host matchers, CSS rules, page-level JS.
enum VideoSite: CaseIterable {
    case youtube
    case bilibili
    case tencent
    case iqiyi
    case youku
    case mgtv
    case tiktok
    case twitter

    /// Host substrings (lowercased) that identify this site. `contains` is
    /// used at the call site, so a single substring like "youtube.com" catches
    /// `m.youtube.com`, `www.youtube.com`, `music.youtube.com`, etc.
    var hostMarkers: [String] {
        switch self {
        case .youtube: ["youtube.com", "youtube-nocookie.com", "youtu.be"]
        case .bilibili: ["bilibili.com", "bili2233.cn", "b23.tv"]
        case .tencent: ["v.qq.com", "vv.video.qq.com", "film.qq.com"]
        case .iqiyi: ["iqiyi.com", "iq.com", "71.am", "pps.tv"]
        case .youku: ["youku.com", "yku.com", "tudou.com"]
        case .mgtv: ["mgtv.com", "imgo.tv", "hitv.com"]
        case .tiktok: ["tiktok.com", "douyin.com", "iesdouyin.com", "snssdk.com"]
        case .twitter: ["twitter.com", "x.com"]
        }
    }

    func matches(_ host: String) -> Bool {
        for marker in hostMarkers where host.contains(marker) {
            return true
        }
        return false
    }

    /// 稳定的站点键：规则文件名（`<key>.css` / `<key>.js`）与远程规则包
    /// `sites` 字典的键都用它（见 `VideoAdRulesStore`）。取自 case 名，别改
    /// case 名。
    var key: String { String(describing: self) }

    /// 站点脚本自己用的"只跑一次"标志位（脚本内部第一件事就是查它）。
    /// 规则热插拔时，新规则要能重跑脚本，所以由外层包装器把它清掉——见
    /// `VideoAdRulesStore.pageJSScript(for:)`。
    var guardFlag: String {
        switch self {
        case .youtube: "__desireYT"
        case .bilibili: "__desireBili"
        case .tencent: "__desireTencent"
        case .iqiyi: "__desireIQiyi"
        case .youku: "__desireYouku"
        case .mgtv: "__desireMGTV"
        case .tiktok: "__desireTikTok"
        case .twitter: "__desireTwitter"
        }
    }

    var css: String {
        switch self {
        case .youtube: Self.youtubeCSS
        case .bilibili: Self.bilibiliCSS
        case .tencent: Self.tencentCSS
        case .iqiyi: Self.iqiyiCSS
        case .youku: Self.youkuCSS
        case .mgtv: Self.mgtvCSS
        case .tiktok: Self.tiktokCSS
        case .twitter: Self.twitterCSS
        }
    }

    var pageScript: String {
        switch self {
        case .youtube: Self.youtubeJS
        case .bilibili: Self.bilibiliJS
        case .tencent: Self.tencentJS
        case .iqiyi: Self.iqiyiJS
        case .youku: Self.youkuJS
        case .mgtv: Self.mgtvJS
        case .tiktok: Self.tiktokJS
        case .twitter: Self.twitterJS
        }
    }
}

// MARK: - Per-site CSS

extension VideoSite {
    static let youtubeCSS = """
/* In-feed & search ads */
ytd-ad-slot-renderer, ytd-display-ad-renderer, ytd-text-ad-renderer,
ytd-compact-promoted-video-renderer, ytd-compact-promoted-item-renderer,
ytd-promoted-sparkles-web-renderer, ytd-promoted-sparkles-text-search-renderer,
ytd-promoted-video-renderer, ytd-action-companion-ad-renderer,
ytd-rich-item-renderer[is-ad], ytd-video-renderer[is-ad],
ytd-compact-video-renderer[is-ad], ytd-grid-video-renderer[is-ad],
yt-lockup-view-model[is-ad], ytd-in-feed-ad-renderer,
ytd-infeed-ad-layout-renderer, ytd-ad-slot,
ytd-ad-simple, yt-about-ad-renderer, ytd-merch-shelf-renderer,
ytd-search-panel-ad-renderer, ytd-unlimited-supply-renderer,
.badge-style-type-ad,
ytd-ad-inline-playback-renderer, ytd-inline-survey-renderer,
ytd-banner-promo-renderer, .ytd-banner-promo-renderer,
ytd-reel-video-renderer[is-ad],
ytm-companion-ad-renderer, ytm-promoted-sparkles-web-renderer,
ytm-rich-item-renderer[is-ad], .ytd-rich-shelf-renderer[is-ad] {
    display: none !important;
}

/* 广告 renderer 的外层网格格子也要一起收起：ytd-rich-item-renderer 的高度由
   网格 CSS 决定，内部 renderer 被隐藏时它不会塌陷，页面上就留下一个等高的
   空框（用户看到的"赞助商广告变成黑框"）。:has() 在 WebKit 15.4+ 可用。 */
ytd-rich-item-renderer:has(ytd-ad-slot-renderer),
ytd-rich-item-renderer:has(ytd-in-feed-ad-renderer),
ytd-rich-item-renderer:has(ytd-display-ad-renderer),
ytd-rich-item-renderer:has(ytd-text-ad-renderer),
ytd-rich-item-renderer:has(ytd-promoted-video-renderer),
ytd-rich-item-renderer:has(ytd-promoted-sparkles-web-renderer),
ytd-rich-item-renderer:has(ytd-compact-promoted-video-renderer),
ytd-rich-item-renderer:has(ytd-infeed-ad-layout-renderer),
yt-lockup-view-model:has(ytd-ad-slot-renderer),
ytd-rich-section-renderer:has(ytd-ad-slot-renderer),
ytd-rich-section-renderer:has(ytd-in-feed-ad-renderer),
ytd-rich-section-renderer:has(ytd-display-ad-renderer),
ytd-rich-section-renderer:has(ytd-promoted-sparkles-web-renderer) {
    display: none !important;
}

/* Masthead / header ads */
#masthead-ad, #header-masthead-ad, .ytp-ad-overlay-container,
yt-mealbar-promo-renderer, .ytp-ad-text-overlay,
.ytp-ad-image-overlay, .ytp-ad-button-icon-modern,
.ytp-ad-skip-button-slot, .ytp-ad-skip-button-container {
    display: none !important;
}

/* Player overlay ads during playback */
.video-ads, .ytp-ad-player-overlay, .ytp-ad-player-overlay-layout,
.ytp-ad-overlay-slot, .ytp-ad-overlay-slot-1, .ytp-ad-overlay-slot-2,
.ytp-ad-text-island, .ytp-ad-overlay-ad-info-button,
.ytp-ad-feedback-dialog, .ytp-ad-action-interstitial,
.ytp-ad-module, .ytp-ad-message-container, .ytp-ad-timed-marker {
    display: none !important;
}

/* Shorts ad slots */
ytd-reel-ad-renderer, ytd-reel-item-renderer[is-ad],
ytd-reel-player-header-renderer[is-ad],
ytd-reel-player-overlay-renderer[is-ad],
ytm-shorts-ad-renderer, ytm-shorts-player-ad-renderer {
    display: none !important;
}

/* Paid promotion overlays (creator-disclosed sponsorship) */
.ytp-paid-content-overlay, .ytp-paid-content-overlay-link,
ytm-paid-content-overlay-renderer, .YtmPaidContentOverlayHost,
[class*="paid-content-overlay"], [class*="PaidContentOverlay"] {
    display: none !important;
    visibility: hidden !important;
    pointer-events: none !important;
}

/* Paid-promotion badge anchor on thumbnails (the small icon top-right) */
a[href*="youtube.com/?p=ppp"],
a[href*="youtube.com/?p=paid_promotion"],
a[href*="/paid_promotion"] {
    display: none !important;
}

/* Companion / "people also watched" ad cluster */
ytd-companion-slot-renderer, ytd-companion-slot,
yt-related-chip-cloud-renderer[component-style="AD_SERIES_WEB"],
.ad-display .ad-container, ytd-engagement-panel-section-list-holder[target-id="engagement-panel-ads"] {
    display: none !important;
}
"""

    static let bilibiliCSS = """
/* Player ads */
.bpx-player-video-ad, .bpx-player-ad, .bpx-player-video-ad-container,
.bpx-ad-container, .bpx-ad-block, .bpx-player-ad-top-container,
.bpx-player-ad-slot, .bpx-player-ad-bottom, .bpx-player-ad-close,
.bili-video-ad, .bilibili-player-video-ad, .bilibili-player-ad,
.bilibili-player-video-ad-bottom, .bpx-player-video-wrap ~ .bpx-player-ad,
.bpx-player-auxiliary-area .bpx-player-ad,
.bilibili-player-ad-bottom, .bilibili-player-promote-wrap {
    display: none !important;
}

/* Page-level & recommendation ads */
.ad-report, .ad-container, .ad-area, .ad-card, .ad-banner,
.banner-ad-container, .video-page-ad, .floor-ad,
.recommend-ad, .recommend-list-ad, .video-card-ad, .feed-card-ad,
.side-ad, .top-ad, .feed-ad, .live-ad, .room-ad,
#ad_bottom, #ad_top, #ad_left, #ad_right, #banner-ad,
#bannerAd, #slide_ad, #reportFirst2, #reportFirst3, #battle-area,
.bili-banner, .bili-grid-card-ad, .floor-card-ad, .bangumi-card-ad,
.popup-ad, .bili-popup, .bili-album__ad, .bg-ad,
.index_ad, .v-wrap .ad, .video-info .ad, .bili-promo,
.bili-promo-card, .bili-promo-list, .bili-guide,
.section-ad, .recommend-card-ad,
.eva-extension-area, .eva-banner, .loc-moveclip,
.video-page-game-card, .video-page-special-card, .video-page-special-card-small,
.activity-m-v1, .home-app-download, .home-content .ad-panel,
.international-home .banner-card, .mascot, .mobile-link-l,
.rank-container .cm-module, .bypb-window .operate-card,
.gg-floor-module, .gg-window .operate-card,
.v-wrap .vcd, .v-wrap #live_recommand_report,
.blocked.new, .room-ctnr + div.flip-view,
.bili-header-m .nav-menu .nav-con .nav-item .text-red,
.nav-link .nav-link-ul .nav-link-item:nth-last-child(1),
.nav-link .nav-link-ul .nav-link-item:nth-last-child(2),
.storey-box div[id*="bili_"] > a[data-loc-id],
.recommend-list .rec-list > :not(.video-page-card) {
    display: none !important;
}

/* Bilibili feed cards with ad marker — newer ad-class on card info */
.bili-video-card__info--ad,
.bili-video-card.is-ad,
.feed-card:has(.bili-video-card__info--ad),
.bili-feed-card:has(.bili-video-card__info--ad),
.bili-rank-list-wrap:has(.bili-rank-list__item--ad),
.video-card:has(.video-card__info--ad) {
    display: none !important;
}

/* "创作推广" / sponsored video markers */
.bili-video-card__info--creative-promotion,
.bili-video-card__creative-promotion,
[class*="--ad"], [class*="ad-mark"], [class*="commercial-marker"] {
    display: none !important;
}

/* Live page ads */
.room-banner, .live-ad-banner, .player-ad,
.home_popularize .adpos, .home_popularize .l-con {
    display: none !important;
}

/* "UP 主分享好物" e-commerce ad unit */
.video-page-goods-card, .goods-card, .bili-goods-card,
.up-share-goods, .bili-share-goods {
    display: none !important;
}
"""

    static let tencentCSS = """
.txp_ad, .txp-ad, .txp_ad_container, .txp_ad_video, .txp_ad_skip,
.tx-ad, .tx-ad-container, .tx-ad-banner, .tx-ad-popup,
.tencent_ad, .qq_ad, .qq_ad_container, .qq-player-ad,
.qq_ad_video, .qq_ad_video_pause, .qq_ad_video_overlay,
.video_ad, .video_ad_skip, .video_ad_pause, .video_ad_overlay,
.player_ad, .player_ad_layer, .ad_layer, .ad_layer_skip,
.adv_cover, .adv_layer, .adv_mask, .pause_ad, .pause_adv,
.c_ad, .c_ad_skip, .c_ad_layer, .c_ad_popup,
.txpp_ad_popup, .txpp-ad-popup, .txpp-ad-mask {
    display: none !important;
}
"""

    static let iqiyiCSS = """
.iq-ad, .iq-ad-container, .iq-ad-slot, .iq-ad-banner,
.iqiyi-ad, .iqiyi-ad-container, .iqiyi-ad-slot, .iqiyi-ad-banner,
.qy-ad, .qy-ad-container, .qy-ad-popup, .qy-player-ad,
.player-ad, .player-ad-layer, .player-ad-skip, .player-ad-overlay,
.pause-ad, .pause-adv, .ad-popup, .ad-layer, .ad-skip,
.advert-layer, .advert-popup, .ad_video, .ad_pause, .ad_overlay,
.video-ad, .video-ad-layer, .video-ad-skip, .video-ad-pause,
.foot-ad, .side-ad, .top-ad, .recommend-ad, .feed-ad,
.banner-ad, .popup-ad, .cover-ad, .mask-ad {
    display: none !important;
}
"""

    static let youkuCSS = """
.youku-ad, .youku-ad-container, .youku-ad-slot, .youku-ad-banner,
.youku-ad-popup, .yk-ad, .yk-ad-container, .yk-ad-popup,
.tudou-ad, .tudou-ad-container, .tudou-ad-popup,
.player-ad, .player-ad-layer, .player-ad-skip, .player-ad-overlay,
.pause-ad, .ad-popup, .ad-layer, .ad-skip, .ad_mask,
.video-ad, .video-ad-layer, .video-ad-skip, .ad_video,
.adv_cover, .adv_layer, .adv_mask, .cover-ad, .popup-ad,
.foot-ad, .side-ad, .top-ad, .recommend-ad, .feed-ad,
.banner-ad, .yk-pause-ad, .yk-cover-ad, .yk-popup-ad {
    display: none !important;
}
"""

    static let mgtvCSS = """
.mg-ad, .mg-ad-container, .mg-ad-slot, .mg-ad-banner,
.mg-ad-popup, .mgtv-ad, .mgtv-ad-container, .mgtv-ad-slot,
.mgtv-ad-banner, .mgtv-ad-popup, .mgtv-ad-pause,
.hitv-ad, .hitv-ad-container, .hitv-ad-popup,
.player-ad, .player-ad-layer, .player-ad-skip, .player-ad-overlay,
.pause-ad, .ad-popup, .ad-layer, .ad-skip, .ad_mask,
.video-ad, .video-ad-layer, .video-ad-skip,
.foot-ad, .side-ad, .top-ad, .recommend-ad, .feed-ad,
.banner-ad, .cover-ad, .popup-ad, .adv_cover, .adv_layer {
    display: none !important;
}
"""

    static let tiktokCSS = """
/* TikTok in-feed ads */
[data-e2e="advertise-card"], [data-e2e="feed-ad"],
.tiktok-ad-card, .tiktok-ad-banner, .tiktok-ad-container,
.tiktok-ad-popup, .tiktok-ad-slot, .tiktok-ad-overlay,
.tiktok-player-ad, .tiktok-player-ad-container,
.tiktok-player-ad-overlay, .tiktok-feed-ad, .tiktok-search-ad,
.douyin-ad, .douyin-ad-card, .douyin-ad-container,
.douyin-ad-popup, .douyin-feed-ad, .douyin-banner-ad,
[class*="-ad-"][class*="-card"], [class^="Ad-"],
[class*="AdContainer"], [class*="AdvertCard"] {
    display: none !important;
}
"""

    static let twitterCSS = """
/* Twitter/X promoted tweets & videos */
[data-testid="placementTracking"], [data-testid="promotedTweet"],
[data-testid="promotedIndicator"], [data-testid="videoPromotedIndicator"],
[data-testid="cellInnerDiv"]:has([data-testid="placementTracking"]),
.twitter-ad, .x-ad, .promoted-tweet, .promoted-account,
.ad-slot, .ad-container, .ad-banner, .ad-popup,
[data-promoted="true"], [data-ad-slot], [data-ad-impression] {
    display: none !important;
}
"""
}

// MARK: - Per-site page scripts

extension VideoSite {
    static let youtubeJS = """
(function() {
    if (window.__desireYT) return;
    window.__desireYT = true;
    var CARD = 'ytd-rich-item-renderer,ytd-video-renderer,ytd-compact-video-renderer,ytd-grid-video-renderer,ytd-reel-item-renderer,yt-lockup-view-model,ytm-rich-item-renderer';
    var STATIC_SLOTS = [
        'ytd-ad-slot-renderer','ytd-display-ad-renderer','ytd-text-ad-renderer',
        'ytd-compact-promoted-video-renderer','ytd-compact-promoted-item-renderer',
        'ytd-promoted-sparkles-web-renderer','ytd-promoted-sparkles-text-search-renderer',
        'ytd-promoted-video-renderer','ytd-action-companion-ad-renderer',
        'ytd-in-feed-ad-renderer','ytd-infeed-ad-layout-renderer','ytd-ad-slot',
        'ytd-ad-simple','yt-mealbar-promo-renderer',
        'ytd-unlimited-supply-renderer','ytd-merch-shelf-renderer',
        'ytd-search-panel-ad-renderer','ytd-reel-ad-renderer',
        'ytd-reel-player-header-renderer','ytd-reel-player-overlay-renderer',
        'ytd-ad-inline-playback-renderer','ytd-inline-survey-renderer',
        'ytd-banner-promo-renderer','ytd-companion-slot-renderer',
        'ytm-companion-ad-renderer','ytm-promoted-sparkles-web-renderer',
        'ytm-shorts-ad-renderer','ytm-shorts-player-ad-renderer',
        'ytd-engagement-panel-section-list-holder[target-id="engagement-panel-ads"]'
    ];
    var AD_LABELS = [
        'ad','ads','advertisement','sponsored','sponsored by','sponsored content',
        'promoted','包含付费推广','赞助商广告','赞助商','赞助','广告','推广',
        'reklam','patrocinado','publicidad','sponsorisé','gesponsert'
    ];
    var PAID_BADGE_HREFS = [
        'youtube.com/?p=ppp',
        'youtube.com/?p=paid_promotion',
        '/paid_promotion'
    ];
    var POST = function(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch(e) {}
    };
    // 广告标签必须"整段就是标签"才算命中。旧版对整张卡片的 textContent 做
    // substring 匹配（任何含 'ad' 的文本都算，如 download / Shadow / ladyboy），
    // 会把正常视频整卡删掉。
    // YouTube 会把标签写成「Ad · 30 秒」「赞助商广告 · 短片」这类组合，先取
    // 首个分隔符前的片段，再做精确比对。
    function adLabel(text) {
        if (!text) return false;
        var t = String(text).trim().toLowerCase().replace(/\\s+/g, ' ');
        t = t.split(' · ')[0].split(' • ')[0].split('｜')[0].trim();
        if (!t || t.length > 24) return false;
        for (var i = 0; i < AD_LABELS.length; i++) {
            if (t === AD_LABELS[i]) return true;
        }
        return false;
    }
    // 只认真正的广告徽章：.badge-style-type-ad，或文本恰为广告标签的徽章。
    // 旧版「卡片里存在任意 ytd-badge-supported-renderer 即判定为广告」会把带
    // 4K / CC / LIVE / 新闻角标 的正常卡片整张删除——实测首页 60 张卡里误删
    // 2 张新闻视频，这正是用户把整个视频广告拦截关掉的原因。
    // 新版徽章是自定义元素 <badge-shape>，文本可能落在 shadow root 里，
    // 直接读 textContent 会拿到空串（真实广告卡片上「赞助商广告」就是这么
    // 藏的）——两种都要看。
    function badgeText(node) {
        var t = (node && node.textContent) || '';
        if (!t && node && node.shadowRoot) t = node.shadowRoot.textContent || '';
        return t;
    }
    function hasAdBadge(el) {
        if (!el) return false;
        if (el.querySelector('.badge-style-type-ad')) return true;
        var badges = el.querySelectorAll('badge-shape, yt-badge-shape-watcher, ytm-badge, [class*="badge-shape"]');
        for (var i = 0; i < badges.length; i++) {
            if (adLabel(badgeText(badges[i]))) return true;
        }
        return false;
    }
    function isPaidBadgeAnchor(a) {
        if (!a || !a.href) return false;
        for (var i = 0; i < PAID_BADGE_HREFS.length; i++) {
            if (a.href.indexOf(PAID_BADGE_HREFS[i]) !== -1) return true;
        }
        return false;
    }
    // 列表页广告 renderer：这些必须连同**外层网格格子**一起删。只删内部
    // renderer 的话，ytd-rich-item-renderer 的尺寸由网格 CSS 决定、不随子节点
    // 塌陷，页面上就留下一个等高的空壳（实测首页留下 4 个 700x494 的"黑框"
    // ——用户报的"赞助商广告变成黑框"）。播放器/页面级 renderer 不在列表内。
    var LIST_AD_SLOTS = [
        'ytd-ad-slot-renderer','ytd-in-feed-ad-renderer','ytd-display-ad-renderer',
        'ytd-text-ad-renderer','ytd-promoted-video-renderer',
        'ytd-promoted-sparkles-web-renderer','ytd-promoted-sparkles-text-search-renderer',
        'ytd-compact-promoted-video-renderer','ytd-compact-promoted-item-renderer',
        'ytd-search-panel-ad-renderer','ytd-ad-slot','ytd-ad-simple',
        'ytd-action-companion-ad-renderer','ytd-infeed-ad-layout-renderer',
        'ytd-unlimited-supply-renderer'
    ];
    var GRID_CELL = 'ytd-rich-item-renderer, ytd-rich-section-renderer, ytd-video-renderer, ' +
        'ytd-compact-video-renderer, ytd-grid-video-renderer, yt-lockup-view-model, ytm-rich-item-renderer';
    function listAdTarget(sel, el) {
        if (LIST_AD_SLOTS.indexOf(sel) === -1) return el;
        return el.closest(GRID_CELL) || el;
    }
    function removeCard(el) {
        if (!el || !el.parentNode) return false;
        el.remove();
        return true;
    }
    // Heavy cosmetic scan — debounced, never run per-mutation.
    function removeAds() {
        var count = 0;
        STATIC_SLOTS.forEach(function(sel) {
            document.querySelectorAll(sel).forEach(function(el) {
                if (removeCard(listAdTarget(sel, el))) count++;
            });
        });
        document.querySelectorAll('[is-ad]').forEach(function(el) {
            var c = el.closest(CARD);
            if (removeCard(c || el)) count++;
        });
        document.querySelectorAll('.badge-style-type-ad').forEach(function(el) {
            if (removeCard(el.closest(CARD))) count++;
        });
        document.querySelectorAll('a').forEach(function(a) {
            if (isPaidBadgeAnchor(a)) {
                var c = a.closest(CARD);
                if (removeCard(c || a)) count++;
            }
        });
        document.querySelectorAll(CARD).forEach(function(card) {
            if (hasAdBadge(card)) {
                if (removeCard(card)) count++;
            }
        });
        document.querySelectorAll('.ytp-paid-content-overlay,[class*="paid-content-overlay"]').forEach(function(el) {
            el.remove(); count++;
        });
        if (count > 0) POST({ site: 'youtube', count: count });
    }

    // ── In-stream ad killer: cheap fast loop, pod-aware ──
    // Primary weapon is 16× SPEED-THROUGH, not seeking: YouTube now fights
    // seekTo (error screens / re-injected ads), but a fast-playing ad is
    // still "playing" — a 30s spot passes in ~2s with no player error.
    var mutedByUs = false;
    var speededByUs = false;
    var origRate = 1;
    var seekPostedThisAd = false;
    var SKIP_SELECTORS = '.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad-button,' +
        '.ytp-ad-skip-button-slot button,.ytp-ad-skip-button-container button,' +
        '.ytp-ad-action-interstitial-skip-button,.ytp-ad-overlay-close-button';
    // Multi-signal ad detection — class names alone break whenever
    // YouTube renames them. The video_id trick is the reliable one: real
    // videos always carry an id, ad creatives report an EMPTY one.
    function adShowing() {
        if (document.querySelector('.ad-showing,.ad-interrupting,.ytp-ad-player-overlay,.ytp-ad-module-active')) return true;
        var p = document.querySelector('#movie_player');
        if (p && p.getVideoData) {
            try {
                var vd = p.getVideoData();
                if (vd && !vd.video_id && p.getPlayerState && p.getPlayerState() === 1) return true;
            } catch(e) {}
        }
        return false;
    }
    function fastTick() {
        var ad = adShowing();
        var v = document.querySelector('video.html5-main-video') ||
                document.querySelector('#movie_player video');
        if (ad) {
            // Mute while ANY ad in the pod plays; restored when it clears.
            if (v && !v.muted) { v.muted = true; mutedByUs = true; }
            // Speed through: remember the user's rate only once, only if
            // sane (≤2×), and restore it when the pod clears.
            if (v && v.playbackRate < 16) {
                origRate = (v.playbackRate > 0 && v.playbackRate <= 2) ? v.playbackRate : 1;
                try { v.playbackRate = 16; speededByUs = true; } catch(e) {}
            }
            var skip = document.querySelector(SKIP_SELECTORS);
            if (skip) {
                skip.click();
                POST({ site: 'youtube', count: 1, action: 'skip' });
            } else {
                var btns = document.querySelectorAll('#movie_player button, #movie_player .ytp-button');
                for (var i = 0; i < btns.length; i++) {
                    var t = (btns[i].textContent || '').trim().toLowerCase();
                    var a = (btns[i].getAttribute('aria-label') || '').toLowerCase();
                    if (t === 'skip' || t.indexOf('skip ad') === 0 || t.indexOf('跳过广告') === 0 ||
                        a.indexOf('skip') === 0 || a.indexOf('跳过') === 0) {
                        btns[i].click();
                        POST({ site: 'youtube', count: 1, action: 'skip' });
                        break;
                    }
                }
            }
            // Seek is now only a FALLBACK (player-API path may still work
            // on some layouts; if YouTube fights it, 16× already won).
            var p = document.querySelector('#movie_player');
            var posted = false;
            if (p && p.getDuration && !speededByUs) {
                try {
                    var d = p.getDuration();
                    if (d > 0 && p.getCurrentTime() < d - 0.4) {
                        p.seekTo(d - 0.3, true);
                        posted = true;
                    }
                } catch(e) {}
            }
            if (posted && !seekPostedThisAd) {
                POST({ site: 'youtube', count: 1, action: 'seek' });
                seekPostedThisAd = true;
            }
        } else {
            // Ad pod cleared — restore volume and playback rate.
            if (mutedByUs && v) { v.muted = false; mutedByUs = false; }
            if (speededByUs && v && v.playbackRate > 2) {
                try { v.playbackRate = origRate; } catch(e) {}
            }
            speededByUs = false;
            seekPostedThisAd = false;
            // Post-roll tail: kill the promo/companion overlays YouTube
            // stacks onto the end screen.
            document.querySelectorAll(
                '.ytp-ad-player-overlay,.ytp-ad-image-overlay,.ytp-ad-text-overlay,' +
                '.ytp-ad-action-interstitial,.ytp-companion-slot,.ytd-merch-shelf-renderer'
            ).forEach(function(el) { el.style.display = 'none'; });
        }
    }

    function dismissPromo() {
        document.querySelectorAll(
            'yt-mealbar-promo-renderer .dismiss-button,' +
            'ytd-popup-container yt-button-renderer,' +
            '.yt-spec-button-shape-next--overlay,' +
            'ytd-single-button-survey-renderer tp-yt-paper-button,' +
            '.ytd-consent-bump-v2-lightbox button'
        ).forEach(function(d) { d.click(); });
    }

    // Debounced slow scan — the observer only schedules it.
    var scanTimer = null;
    function scheduleScan() {
        if (scanTimer) return;
        scanTimer = setTimeout(function() {
            scanTimer = null;
            removeAds();
            dismissPromo();
        }, 600);
    }

    var obs = new MutationObserver(scheduleScan);
    function attach() {
        if (document.body) {
            obs.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['is-ad','class','href'] });
        }
    }
    if (document.body) attach(); else document.addEventListener('DOMContentLoaded', attach);
    [50,150,400,800,1500,2500,4000,6000,9000,14000,20000,30000].forEach(function(t) {
        setTimeout(function() { removeAds(); dismissPromo(); }, t);
    });
    var n = 0;
    var poll = setInterval(function() { scheduleScan(); if (++n > 40) clearInterval(poll); }, 2000);
    setInterval(fastTick, 300);
    window.addEventListener('yt-navigate-finish', function() { setTimeout(function() { removeAds(); dismissPromo(); }, 300); });
    window.addEventListener('yt-page-data-updated', function() { setTimeout(function() { removeAds(); dismissPromo(); }, 300); });
})();
"""

    static let bilibiliJS = """
(function() {
    if (window.__desireBili) return;
    window.__desireBili = true;
    var POST = function(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch(e) {}
    };
    // Container selectors for video feed cards. Removing one of these
    // removes the whole sponsored video entry.
    var CARD = '.bili-video-card,.video-card,.feed-card,.bili-feed-card,.recommend-list .video-card,.bili-rank-list__item,.recommend-card';
    // Labels that mark a "恰饭" / "创作推广" / sponsored disclosure. Matched
    // as WHOLE labels (see `adLabel`), never as substrings of a card's text:
    // substring matching removed any card whose title merely mentioned 广告 /
    // 推广 / 'ad' (same bug class as the YouTube list rules).
    var AD_LABELS = [
        '广告','推广','恰饭','商务合作','商单','合作推广',
        '创作推广','商业推广','付费推广','包含推广',
        'ad','ads','sponsored','promoted','sponsored by'
    ];
    // 命中条件：某个元素"整段文本就是广告标签"（标签常见写法「广告 · xxx」，
    // 取首个分隔符前的片段）。卡片标题/UP 名里出现这些词不算。
    function adLabel(text) {
        if (!text) return false;
        var t = String(text).trim().replace(/\\s+/g, ' ');
        t = t.split(' · ')[0].split(' • ')[0].split('|')[0].trim();
        if (!t || t.length > 16) return false;
        for (var i = 0; i < AD_LABELS.length; i++) {
            if (t.toLowerCase() === AD_LABELS[i].toLowerCase()) return true;
        }
        return false;
    }
    function hasAdLabel(el) {
        if (!el) return false;
        var nodes = el.querySelectorAll('span,i,em,b,div[class*="tag"],div[class*="badge"],[class*="--ad"]');
        for (var i = 0; i < nodes.length; i++) {
            if (adLabel(nodes[i].textContent)) return true;
        }
        return false;
    }
    function removeCard(el) {
        if (!el || !el.parentNode) return false;
        el.remove();
        return true;
    }
    function removeAds() {
        var count = 0;
        // 1) Static player & page-level slots
        var sel = [
            // Player ads
            '.bpx-player-video-ad','.bpx-player-ad','.bili-video-ad','.ad-report','.ad-container','.ad-area',
            '.bpx-player-ad-top-container','.bpx-player-ad-slot','.bpx-player-ad-bottom','.bpx-player-ad-close',
            // Page-level banner / popup
            '.video-page-ad','.floor-ad','.recommend-ad','.video-card-ad','.feed-card-ad',
            '.side-ad','.top-ad','.feed-ad','.live-ad','.room-ad',
            '.bili-banner','.bili-grid-card-ad','.floor-card-ad','.bangumi-card-ad',
            '.popup-ad','.bili-popup','.bili-album__ad','.bg-ad',
            '.section-ad','.recommend-card-ad',
            // Newer selectors
            '.bpx-player-auxiliary-area .bpx-player-ad','.bpx-player-video-wrap ~ .bpx-player-ad',
            '#bannerAd','#slide_ad','#reportFirst2','#reportFirst3',
            '.eva-extension-area','.eva-banner','.loc-moveclip',
            '.video-page-game-card','.video-page-special-card','.video-page-special-card-small',
            '.activity-m-v1','.home-app-download','.home-content .ad-panel',
            '.international-home .banner-card','.mascot','.mobile-link-l',
            '.rank-container .cm-module','.bypb-window .operate-card',
            '.gg-floor-module','.gg-window .operate-card',
            '.bilibili-player-promote-wrap','.blocked.new',
            // E-commerce
            '.video-page-goods-card','.goods-card','.bili-goods-card','.up-share-goods','.bili-share-goods'
        ];
        sel.forEach(function(s) {
            document.querySelectorAll(s).forEach(function(el) {
                if (removeCard(el)) count++;
            });
        });
        // 2) Cards with explicit ad-info class
        document.querySelectorAll('.bili-video-card__info--ad,.bili-video-card.is-ad,[class*="--ad"]').forEach(function(marker) {
            var c = marker.closest(CARD);
            if (removeCard(c || marker)) count++;
        });
        // 3) Cards carrying an ad disclosure label (whole-label match only)
        document.querySelectorAll(CARD).forEach(function(card) {
            if (hasAdLabel(card)) {
                if (removeCard(card)) count++;
            }
        });
        // 4) Hide entire ad-report siblings of video
        document.querySelectorAll('.bpx-player-video-wrap').forEach(function(w) {
            var a = w.closest('.bpx-player-video-ad');
            if (removeCard(a)) count++;
        });
        // 5) Popup / guide overlay
        document.querySelectorAll('.bili-popup, .popup-ad, .bili-guide, .nav-link .nav-link-ul .nav-link-item:nth-last-child(-n+2)').forEach(function(el) {
            if (removeCard(el)) count++;
        });
        if (count > 0) POST({ site: 'bilibili', count: count });
    }
    function skipAd() {
        var skip = document.querySelector('.bpx-player-skip-button, .bpx-player-ad-skip, .bpx-player-video-ad-skip');
        if (skip) { skip.click(); POST({ site: 'bilibili', count: 1, action: 'skip' }); }
        var v = document.querySelector('.bpx-player-video-wrap video');
        if (v && v.duration > 0 && v.currentTime < v.duration - 0.5) {
            try { v.currentTime = v.duration - 0.3; POST({ site: 'bilibili', count: 1, action: 'seek' }); } catch(e) {}
        }
    }
    function runAll() { removeAds(); skipAd(); }
    var obs = new MutationObserver(runAll);
    function attach() {
        if (document.body) obs.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
    }
    if (document.body) attach(); else document.addEventListener('DOMContentLoaded', attach);
    // 12 staggered retries — B站 SPA is slow to render feed cards on scroll
    [200,600,1500,3000,6000,10000,15000,22000,30000].forEach(function(t) { setTimeout(runAll, t); });
})();
"""

    static let tencentJS = """
(function() {
    if (window.__desireTencent) return;
    window.__desireTencent = true;
    var POST = function(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch(e) {}
    };
    var SEL = [
        '.txp_ad','.txp-ad','.txp_ad_container','.txp_ad_video','.txp_ad_skip',
        '.tx-ad','.tx-ad-container','.tx-ad-banner','.tx-ad-popup',
        '.tencent_ad','.qq_ad','.qq_ad_container','.qq-player-ad',
        '.video_ad','.video_ad_skip','.video_ad_pause','.video_ad_overlay',
        '.player_ad','.player_ad_layer','.ad_layer','.ad_layer_skip',
        '.adv_cover','.adv_layer','.adv_mask','.pause_ad','.pause_adv',
        '.c_ad','.c_ad_skip','.c_ad_layer','.c_ad_popup',
        '.txpp_ad_popup','.txpp-ad-popup','.txpp-ad-mask'
    ].join(',');
    function removeAds() {
        var count = 0;
        document.querySelectorAll(SEL).forEach(function(el) { el.remove(); count++; });
        if (count > 0) POST({ site: 'tencent', count: count });
    }
    function skipAd() {
        var skip = document.querySelector('.txp_ad_skip, .video_ad_skip, .c_ad_skip, [class*="skip"]');
        if (skip) { skip.click(); POST({ site: 'tencent', count: 1, action: 'skip' }); }
        var v = document.querySelector('video');
        if (v && v.duration > 0 && v.currentTime < v.duration - 0.5) {
            try { v.currentTime = v.duration - 0.3; POST({ site: 'tencent', count: 1, action: 'seek' }); } catch(e) {}
        }
    }
    function runAll() { removeAds(); skipAd(); }
    var obs = new MutationObserver(runAll);
    if (document.body) obs.observe(document.body, { childList: true, subtree: true, attributes: true });
    [200,800,2000,5000,10000].forEach(function(t) { setTimeout(runAll, t); });
})();
"""

    static let iqiyiJS = """
(function() {
    if (window.__desireIQiyi) return;
    window.__desireIQiyi = true;
    var POST = function(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch(e) {}
    };
    var SEL = [
        '.iq-ad','.iq-ad-container','.iq-ad-slot','.iq-ad-banner',
        '.iqiyi-ad','.iqiyi-ad-container','.iqiyi-ad-slot','.iqiyi-ad-banner',
        '.qy-ad','.qy-ad-container','.qy-ad-popup','.qy-player-ad',
        '.player-ad','.player-ad-layer','.player-ad-skip','.player-ad-overlay',
        '.pause-ad','.ad-popup','.ad-layer','.ad-skip','.advert-layer','.advert-popup',
        '.video-ad','.video-ad-layer','.video-ad-skip','.foot-ad','.side-ad','.top-ad',
        '.recommend-ad','.feed-ad','.banner-ad','.popup-ad','.cover-ad','.mask-ad'
    ].join(',');
    function removeAds() {
        var count = 0;
        document.querySelectorAll(SEL).forEach(function(el) { el.remove(); count++; });
        if (count > 0) POST({ site: 'iqiyi', count: count });
    }
    function skipAd() {
        var skip = document.querySelector('.player-ad-skip, .video-ad-skip, [class*="skip"]');
        if (skip) { skip.click(); POST({ site: 'iqiyi', count: 1, action: 'skip' }); }
        var v = document.querySelector('video');
        if (v && v.duration > 0 && v.currentTime < v.duration - 0.5) {
            try { v.currentTime = v.duration - 0.3; POST({ site: 'iqiyi', count: 1, action: 'seek' }); } catch(e) {}
        }
    }
    function runAll() { removeAds(); skipAd(); }
    var obs = new MutationObserver(runAll);
    if (document.body) obs.observe(document.body, { childList: true, subtree: true });
    [200,800,2000,5000,10000].forEach(function(t) { setTimeout(runAll, t); });
})();
"""

    static let youkuJS = """
(function() {
    if (window.__desireYouku) return;
    window.__desireYouku = true;
    var POST = function(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch(e) {}
    };
    var SEL = [
        '.youku-ad','.youku-ad-container','.youku-ad-slot','.youku-ad-banner','.youku-ad-popup',
        '.yk-ad','.yk-ad-container','.yk-ad-popup',
        '.tudou-ad','.tudou-ad-container','.tudou-ad-popup',
        '.player-ad','.player-ad-layer','.player-ad-skip','.player-ad-overlay',
        '.pause-ad','.ad-popup','.ad-layer','.ad-skip','.ad_mask',
        '.video-ad','.video-ad-layer','.video-ad-skip','.adv_cover','.adv_layer','.adv_mask',
        '.foot-ad','.side-ad','.top-ad','.recommend-ad','.feed-ad','.banner-ad',
        '.yk-pause-ad','.yk-cover-ad','.yk-popup-ad'
    ].join(',');
    function removeAds() {
        var count = 0;
        document.querySelectorAll(SEL).forEach(function(el) { el.remove(); count++; });
        if (count > 0) POST({ site: 'youku', count: count });
    }
    function skipAd() {
        var skip = document.querySelector('.player-ad-skip, [class*="skip"]');
        if (skip) { skip.click(); POST({ site: 'youku', count: 1, action: 'skip' }); }
        var v = document.querySelector('video');
        if (v && v.duration > 0 && v.currentTime < v.duration - 0.5) {
            try { v.currentTime = v.duration - 0.3; POST({ site: 'youku', count: 1, action: 'seek' }); } catch(e) {}
        }
    }
    function runAll() { removeAds(); skipAd(); }
    var obs = new MutationObserver(runAll);
    if (document.body) obs.observe(document.body, { childList: true, subtree: true });
    [200,800,2000,5000,10000].forEach(function(t) { setTimeout(runAll, t); });
})();
"""

    static let mgtvJS = """
(function() {
    if (window.__desireMGTV) return;
    window.__desireMGTV = true;
    var POST = function(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch(e) {}
    };
    var SEL = [
        '.mg-ad','.mg-ad-container','.mg-ad-slot','.mg-ad-banner','.mg-ad-popup',
        '.mgtv-ad','.mgtv-ad-container','.mgtv-ad-slot','.mgtv-ad-banner','.mgtv-ad-popup','.mgtv-ad-pause',
        '.hitv-ad','.hitv-ad-container','.hitv-ad-popup',
        '.player-ad','.player-ad-layer','.player-ad-skip','.player-ad-overlay',
        '.pause-ad','.ad-popup','.ad-layer','.ad-skip','.ad_mask',
        '.video-ad','.video-ad-layer','.video-ad-skip',
        '.foot-ad','.side-ad','.top-ad','.recommend-ad','.feed-ad','.banner-ad','.cover-ad','.popup-ad',
        '.adv_cover','.adv_layer'
    ].join(',');
    function removeAds() {
        var count = 0;
        document.querySelectorAll(SEL).forEach(function(el) { el.remove(); count++; });
        if (count > 0) POST({ site: 'mgtv', count: count });
    }
    function skipAd() {
        var skip = document.querySelector('.player-ad-skip, [class*="skip"]');
        if (skip) { skip.click(); POST({ site: 'mgtv', count: 1, action: 'skip' }); }
        var v = document.querySelector('video');
        if (v && v.duration > 0 && v.currentTime < v.duration - 0.5) {
            try { v.currentTime = v.duration - 0.3; POST({ site: 'mgtv', count: 1, action: 'seek' }); } catch(e) {}
        }
    }
    function runAll() { removeAds(); skipAd(); }
    var obs = new MutationObserver(runAll);
    if (document.body) obs.observe(document.body, { childList: true, subtree: true });
    [200,800,2000,5000,10000].forEach(function(t) { setTimeout(runAll, t); });
})();
"""

    static let tiktokJS = """
(function() {
    if (window.__desireTikTok) return;
    window.__desireTikTok = true;
    var POST = function(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch(e) {}
    };
    var SEL = [
        '[data-e2e="advertise-card"]','[data-e2e="feed-ad"]',
        '.tiktok-ad-card','.tiktok-ad-banner','.tiktok-ad-container',
        '.tiktok-ad-popup','.tiktok-ad-slot','.tiktok-ad-overlay',
        '.tiktok-player-ad','.tiktok-player-ad-container','.tiktok-player-ad-overlay',
        '.tiktok-feed-ad','.tiktok-search-ad',
        '.douyin-ad','.douyin-ad-card','.douyin-ad-container',
        '.douyin-ad-popup','.douyin-feed-ad','.douyin-banner-ad',
        '[class*="-ad-"][class*="-card"]','[class^="Ad-"]',
        '[class*="AdContainer"]','[class*="AdvertCard"]'
    ].join(',');
    function removeAds() {
        var count = 0;
        document.querySelectorAll(SEL).forEach(function(el) {
            var c = el.closest('[data-e2e="feed-item"], [data-e2e="user-post-item"], div[class*="DivItemContainer"]');
            (c || el).remove();
            count++;
        });
        if (count > 0) POST({ site: 'tiktok', count: count });
    }
    function skipAd() {
        var skip = document.querySelector('[data-e2e="skip-ad"], [class*="skipAd"], [class*="SkipAd"]');
        if (skip) { skip.click(); POST({ site: 'tiktok', count: 1, action: 'skip' }); }
        var v = document.querySelector('video');
        if (v && v.duration > 0 && v.currentTime < v.duration - 0.5) {
            try { v.currentTime = v.duration - 0.3; POST({ site: 'tiktok', count: 1, action: 'seek' }); } catch(e) {}
        }
    }
    function runAll() { removeAds(); skipAd(); }
    var obs = new MutationObserver(runAll);
    if (document.body) obs.observe(document.body, { childList: true, subtree: true });
    [200,800,2000,5000,10000].forEach(function(t) { setTimeout(runAll, t); });
})();
"""

    static let twitterJS = """
(function() {
    if (window.__desireTwitter) return;
    window.__desireTwitter = true;
    var POST = function(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch(e) {}
    };
    function removeAds() {
        var count = 0;
        // Whole promoted tweet cells
        document.querySelectorAll('[data-testid="cellInnerDiv"]').forEach(function(cell) {
            if (cell.querySelector('[data-testid="placementTracking"],[data-testid="promotedTweet"],[data-promoted="true"]')) {
                cell.remove();
                count++;
            }
        });
        // Floating ads
        document.querySelectorAll('[data-testid="placementTracking"],[data-testid="promotedTweet"],[data-testid="videoPromotedIndicator"],[data-promoted="true"]').forEach(function(el) {
            el.remove();
            count++;
        });
        if (count > 0) POST({ site: 'twitter', count: count });
    }
    function skipAd() {
        var v = document.querySelector('video');
        if (v && v.duration > 0 && v.currentTime < v.duration - 0.5) {
            try { v.currentTime = v.duration - 0.3; POST({ site: 'twitter', count: 1, action: 'seek' }); } catch(e) {}
        }
    }
    function runAll() { removeAds(); skipAd(); }
    var obs = new MutationObserver(runAll);
    if (document.body) obs.observe(document.body, { childList: true, subtree: true });
    [200,800,2000,5000,10000].forEach(function(t) { setTimeout(runAll, t); });
})();
"""
}
