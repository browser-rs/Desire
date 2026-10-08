// yt-anti-detect.js — YouTube 反"广告拦截检测"（0.7.1 走查实测：YouTube
// 识别到拦截并弹"检测到广告拦截器"弹窗 + 暂停播放）。
//
// 注入：主框架 atDocumentStart（必须先于 YouTube 的播放器脚本）。
// 三层对策（均为被动防御， Arms race 常态化，按 2025 主流检测面覆盖）：
//   ① ytInitialPlayerResponse 陷阱：拦截赋值，剥离 adPlacements / adSlots /
//      adBreaks 字段——播放器读到的播放器响应里根本没有广告位声明；
//   ② 检测弹窗清除：MutationObserver 盯 enforcement 弹窗
//      （ytd-enforcement-message-view-model / tp-yt-paper-dialog 含
//      "广告拦截"/"ad blocker" 文案）——出现即移除并恢复 <video> 播放；
//   ③ bait 元素清除：#player-ads 等诱饵位在 DOMContentLoaded 后整节点移除
//      ——visibility 检测读到"节点不存在"而非"被隐藏"（getComputedStyle
//      检测的对策是存在而非可见）。
(function() {
    'use strict';
    if (!/(^|\.)(youtube\.com|youtube-nocookie\.com)$/.test(location.hostname)) return;
    if (window.__desireYTAntiDetect) return;
    window.__desireYTAntiDetect = true;

    // ---- ① ytInitialPlayerResponse 陷阱 ----
    // YouTube 的内联脚本做 `window.ytInitialPlayerResponse = {...}`——
    // defineProperty 的 set 先剥离广告位字段再落袋。
    function stripAds(obj) {
        if (!obj || typeof obj !== 'object') return obj;
        try {
            delete obj.adPlacements;
            delete obj.adSlots;
            delete obj.adBreaks;
            if (obj.adPlacements) obj.adPlacements = [];
            if (obj.adSlots) obj.adSlots = [];
        } catch (e) {}
        return obj;
    }
    try {
        var _ipr;
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
            configurable: true,
            get: function() { return _ipr; },
            set: function(v) { _ipr = stripAds(v); }
        });
    } catch (e) {}

    // ---- ② 检测弹窗清除 + 播放恢复 ----
    var ENFORCEMENT = 'ytd-enforcement-message-view-model';
    var AD_TEXT = /ad.?block|广告拦截|拦截广告|广告过滤/i;

    function killDialog(dialog) {
        dialog.remove();
        var vids = document.querySelectorAll('video');
        vids.forEach(function(v) { v.play().catch(function() {}); });
    }
    function scanDialogs(root) {
        try {
            if (root.querySelectorAll) {
                root.querySelectorAll('tp-yt-paper-dialog, ytd-popup-container ~ *').forEach(function(d) {
                    if (d.querySelector(ENFORCEMENT) || AD_TEXT.test(d.textContent || '')) killDialog(d);
                });
                var em = root.querySelectorAll(ENFORCEMENT);
                em.forEach(function(m) {
                    var dialog = m.closest('tp-yt-paper-dialog') || m.closest('ytd-popup-container') || m;
                    killDialog(dialog);
                });
            }
        } catch (e) {}
    }
    var mo = new MutationObserver(function(muts) {
        for (var i = 0; i < muts.length; i++) {
            var added = muts[i].addedNodes;
            for (var j = 0; j < added.length; j++) {
                var n = added[j];
                if (n.nodeType === 1 && (n.matches && (n.matches('tp-yt-paper-dialog') || n.querySelector('tp-yt-paper-dialog, ytd-popup-container')))) {
                    scanDialogs(document);
                    return;
                }
            }
        }
    });
    try {
        mo.observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}

    // ---- ③ bait 元素清除（DOMContentLoaded 后整节点移除）----
    var BAITS = ['#player-ads', 'ytd-mealbar-promo-renderer', '#masthead-ad'];
    function clearBaits() {
        BAITS.forEach(function(sel) {
            document.querySelectorAll(sel).forEach(function(el) { el.remove(); });
        });
    }
    // YouTube 是 SPA：bait 元素会在路由/渲染后重建——并入 MutationObserver
    // 持续清除（观察器常驻，与弹窗清除互补）。
    var baitObserver = new MutationObserver(clearBaits);
    if (document.documentElement) {
        baitObserver.observe(document.documentElement, { childList: true, subtree: true });
    }
})();
