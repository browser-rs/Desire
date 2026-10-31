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

    // ---- ② 检测弹窗清除（2026-11-01 重写——旧版是"播一下马上暂停"的真凶）----
    // 旧版灾难：选择器 `ytd-popup-container ~ *` 把 popup 容器之后的所有兄弟
    // （含主内容区）纳入 AD_TEXT 的 textContent 全文匹配——watch 页推荐/评论
    // 里必然出现"广告拦截"字样 → 误判 → killDialog 把真 DOM remove() 掉并
    // 强制 play() 所有 <video>，YouTube 播放器状态机随即 pauseVideo() 反杀
    // （诊断栈帧 killDialog@user-script 逐行对上，2026-10-31 取证）。
    //
    // 新规则（三重收窄，宁漏勿伤）：
    //   ① 只认 `tp-yt-paper-dialog` 里**含 ENFORCEMENT 元素**的（结构证据，
    //      不做全文文案匹配——正文几千字必误命中）；
    //   ② remove() 后**不再强制 play()**——播放恢复交给既有管线
    //      （yt-playback-guard 起播 / media-visibility-resume 恢复），
    //      外部 play() 与播放器状态机打架正是"播一下马上暂停"的机制；
    //   ③ 弹窗出现但 800ms 内未确认是 enforcement 的，只隐藏不移除
    //      （SPA 渲染中途误删不可逆，隐藏可由 YouTube 自行恢复）。
    var ENFORCEMENT = 'ytd-enforcement-message-view-model';

    function killDialog(dialog) {
        dialog.remove();
    }

    function scanDialogs(root) {
        try {
            if (!root.querySelectorAll) return;
            root.querySelectorAll('tp-yt-paper-dialog').forEach(function(d) {
                // 结构证据：弹窗内必须有 enforcement 视图模型才动手。
                if (d.querySelector(ENFORCEMENT)) killDialog(d);
            });
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
