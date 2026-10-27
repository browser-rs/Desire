// yt-playback-guard.js — YouTube 播放起播与海报守卫（2026-10-21）
//
// 两件事，都只在 youtube.com 主框架生效：
//
// ① **起播补刀**（仅当该标签生效的自动播放策略是 allowAll）：YouTube 在
//    WKWebView 里对新文档经常停在 unstarted 状态——播放器的 play() 试过
//    一次就放弃，player 状态 -1、画面停在 0 秒。策略已允许自动播放时，
//    轮询几次调用 `movie_player.playVideo()`（等价用户点播放键），把首帧
//    真正拉起来。只在页面可见、视频仍在起点、没有广告时动作；最多 4 次，
//    URL 一变重新计数。用户自己暂停（currentTime > 0.5）后不再干预。
//
// ② **海报守卫**：策略要求用户手势时，YouTube 的 play() 被拒后有时会把
//    `.ytp-cued-thumbnail-overlay-image` 留成 `display:none !important`，
//    而大播放键还在——玩家看到的就是纯黑 + 播放键（用户 2026-10-21 报的
//    "黑屏，点播放才开始"）。检测"暂停在起点 + 无广告 + unstarted"时把
//    海报显示回来；起播后 YouTube 自己会再次隐藏，不冲突。
//
// 注入：WebView 创建期 atDocumentEnd，主框架；`__DESIRE_AUTOPLAY_ALLOWED__`
// 由 Swift 侧替换成 true/false（见 WebView.init）。
(function () {
    'use strict';
    if (!/(^|\.)(youtube\.com|youtube-nocookie\.com)$/.test(location.hostname)) return;
    if (window.__desireYTPlaybackGuard) return;
    window.__desireYTPlaybackGuard = true;

    var AUTOPLAY_ALLOWED = __DESIRE_AUTOPLAY_ALLOWED__;
    // 2026-10-23：原来只试 4 次（7s 内）。播放器/网络慢时全部落空，用户看到
    // 的就是"转圈、点播放立刻能播"。窗口拉长到 30s，并允许切回前台后重试。
    var KICK_DELAYS = [1200, 2600, 4500, 7000, 11000, 16000, 22000, 30000];
    var timers = [];
    var currentKey = '';
    var tries = 0;

    // 用户点在播放器/视频上的交互才算接管（点页面别处/滚动不算）。
    // SPA 换视频（schedule 里 URL 变化）会重置——新视频的起播由新一轮决定。
    var userTouched = false;
    ['pointerdown', 'touchstart'].forEach(function(t) {
        document.addEventListener(t, function(e) {
            try {
                var el = e.target;
                if (el && el.closest && (el.closest('#movie_player') || el.closest('video'))) {
                    userTouched = true;
                }
            } catch (err) {}
        }, { capture: true, passive: true });
    });

    function clearTimers() {
        for (var i = 0; i < timers.length; i++) clearTimeout(timers[i]);
        timers = [];
    }
    function player() { return document.getElementById('movie_player'); }
    function video() {
        return document.querySelector('video.html5-main-video') || document.querySelector('video');
    }
    function isWatchPage() { return /^\/(watch|shorts|embed)/.test(location.pathname); }
    function adShowing() { return !!document.querySelector('.ad-showing'); }

    function restorePoster() {
        var img = document.querySelector('.ytp-cued-thumbnail-overlay-image');
        if (!img) return;
        if (getComputedStyle(img).display === 'none') {
            // YouTube 用的是内联 !important，必须同权重覆盖。
            img.style.setProperty('display', 'block', 'important');
        }
    }

    function guardPoster() {
        var v = video(), p = player();
        if (!v || !p) return;
        if (!v.paused || v.currentTime > 0.5) return;
        if (adShowing()) return;
        if (!/unstarted-mode/.test(p.className)) return;
        restorePoster();
    }

    function nudgeElement() {
        var vv = video();
        if (vv && vv.paused && vv.currentTime <= 0.5 && !userTouched) {
            try { vv.play().catch(function() {}); } catch (e2) {}
        }
    }

    function kick() {
        if (!AUTOPLAY_ALLOWED || !isWatchPage() || userTouched) return;
        if (document.visibilityState !== 'visible') return;
        var v = video(), p = player();
        if (!v || !p) return;
        if (!v.paused || v.currentTime > 0.5) return;
        // 广告播放中也不要跳过：暂停在起点说明播放器根本没起来，playVideo()
        // 会把广告/正片推进到播放态（YouTube 自己的播放键也是同一个入口）。
        tries++;
        try { if (p.playVideo) p.playVideo(); } catch (e) {}
        setTimeout(nudgeElement, 700);
    }

    function schedule() {
        var key = location.pathname + location.search;
        if (key === currentKey) return;
        currentKey = key;
        clearTimers();
        tries = 0;
        userTouched = false;
        if (!isWatchPage()) return;
        if (AUTOPLAY_ALLOWED) {
            for (var i = 0; i < KICK_DELAYS.length; i++) {
                timers.push(setTimeout(function () {
                    if (tries < KICK_DELAYS.length) kick();
                }, KICK_DELAYS[i]));
            }
        }
        [700, 1800, 3200].forEach(function (ms) {
            timers.push(setTimeout(guardPoster, ms));
        });
    }

    document.addEventListener('yt-navigate-finish', schedule, true);
    window.addEventListener('popstate', schedule);
    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') {
            // 后台标签页的补刀机会已过（kick 在隐藏时不动），回到前台补一次。
            kick();
            guardPoster();
        }
    });

    // SPA 路由事件在部分播放器版本不派发到 document：URL 轮询兜底（幂等）。
    var lastHref = location.href;
    setInterval(function () {
        if (location.href !== lastHref) {
            lastHref = location.href;
            schedule();
        }
        guardPoster();
        pauseOffscreenPreviews();
    }, 1000);

    // 首页/列表页的缩略图预览播放器（v0.8.14）：YouTube 对 hover 预览预创建
    // <video> 并立刻 load()，被 WebKit 判 'Not enough data' 反复拦（实测 898
    // 条 consent block 全来自这里）——白烧 CPU 与预取带宽，也让详情页共享
    // 的网络管线变慢。非可视区的 video 一律暂停并清 src，进可视区才放行。
    function pauseOffscreenPreviews() {
        if (isWatchPage()) return;
        var vids = document.querySelectorAll('video');
        for (var i = 0; i < vids.length; i++) {
            var v = vids[i];
            var r = v.getBoundingClientRect();
            var visible = r.width > 0 && r.height > 0 &&
                r.bottom > 0 && r.top < window.innerHeight;
            if (!visible) {
                if (!v.paused) { try { v.pause(); } catch (e) {} }
            }
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', schedule);
    } else {
        schedule();
    }
})();
