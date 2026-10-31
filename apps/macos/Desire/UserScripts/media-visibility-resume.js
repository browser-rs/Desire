// media-visibility-resume.js — 页面可见性恢复补播（v0.8.31 热修）
//
// 现场（2026-10-31 统一日志取证）：YouTube 播放中切走标签再切回，
// WebKit 走 visibilityChanged: showing → "Resuming silent playback" →
// resumeAutoplaying 被拦（PageConsentRequired: !autoplay）——视频卡在
// 暂停。既有的起播三层（kick/re-bake/海报守卫）都只管首帧，白名单
// 之外的嵌入式播放器更是零覆盖；这条恢复路径此前没有任何一层接住。
//
// 机制：记录页面隐藏瞬间主视频（视口最大的 <video>）是否在播；回到
// 可见时若视频卡在 paused 且隐藏前在播（= 被系统拦下，不是用户暂停）
// → 页面内调 play() 补播（用户此前点过播放器，激活通常已在），
// 失败重试 2 次。全站生效，与 YouTube guard 的起播 kick 幂等共存。
//
// 用户主动暂停的判定：可见状态下的 pause 事件一律视为用户/页面主动
// 暂停（尊重，不补播）；仅"隐藏前在播 → 可见后 paused"这一种形态补。
//
// 注入：WebView 创建期 atDocumentEnd，全框架（嵌入播放器同样受益）。
(function () {
    'use strict';
    if (window.__desireVisibilityResume) return;
    window.__desireVisibilityResume = true;

    var wasPlayingAtHide = false;
    var retriesLeft = 0;

    function mainVideo() {
        var vids = document.querySelectorAll('video');
        var best = null, bestArea = 0;
        for (var i = 0; i < vids.length; i++) {
            var v = vids[i];
            var r = v.getBoundingClientRect();
            var area = r.width * r.height;
            if (area > bestArea) { bestArea = area; best = v; }
        }
        return best;
    }

    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'hidden') {
            var v = mainVideo();
            wasPlayingAtHide = !!(v && !v.paused && !v.ended);
            retriesLeft = 0;
            return;
        }
        // visible：隐藏前在播、现在卡暂停 → 补播。
        if (!wasPlayingAtHide) return;
        var video = mainVideo();
        if (!video || !video.paused || video.ended) { wasPlayingAtHide = false; return; }
        wasPlayingAtHide = false;
        retriesLeft = 2;
        var attempt = function () {
            if (!video.paused || video.ended) return;
            var p = video.play();
            if (p && p.catch) {
                p.catch(function () {
                    if (retriesLeft > 0) {
                        retriesLeft -= 1;
                        setTimeout(attempt, 350);
                    }
                });
            }
        };
        attempt();
        setTimeout(attempt, 350);
        setTimeout(attempt, 900);
    }, true);

    // 可见状态下的 pause：用户/页面主动暂停——清标记，绝不补播。
    document.addEventListener('pause', function (e) {
        var t = e.target;
        if (!(t instanceof HTMLVideoElement)) return;
        if (document.visibilityState === 'visible') {
            var main = mainVideo();
            if (t === main) wasPlayingAtHide = false;
        }
    }, true);
})();
