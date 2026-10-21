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
    var KICK_DELAYS = [1200, 2600, 4500, 7000];
    var timers = [];
    var currentKey = '';
    var tries = 0;

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

    function kick() {
        if (!AUTOPLAY_ALLOWED || !isWatchPage()) return;
        if (document.visibilityState !== 'visible') return;
        var v = video(), p = player();
        if (!v || !p) return;
        if (!v.paused || v.currentTime > 0.5) return;
        if (adShowing()) return;
        tries++;
        try { p.playVideo(); } catch (e) {}
        // playVideo() 偶尔只把状态机推进到缓冲；再补一次元素级 play()。
        setTimeout(function () {
            var vv = video();
            if (vv && vv.paused && vv.currentTime <= 0.5 && !adShowing()) {
                try { vv.play().catch(function () {}); } catch (e2) {}
            }
        }, 700);
    }

    function schedule() {
        var key = location.pathname + location.search;
        if (key === currentKey) return;
        currentKey = key;
        clearTimers();
        tries = 0;
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
    }, 1000);

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', schedule);
    } else {
        schedule();
    }
})();
