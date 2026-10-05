// video-speed.js
// Source: Desire/Features/Tabs/TabAudioControl.swift 同族的页面速率控制（0.6.5）
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false, page world
// 视频速度控制数据面：
//  - window.__desireVideoSpeed.set(rate)：对当前与未来所有 video/audio 元素
//    应用 playbackRate（MutationObserver 保持新元素；preservePitch 恒 true）
//  - rate != 1 时右下角显示速率徽章，8s 后淡出（与站点自带速度控制并存时
//    徽章只反映 Desire 的接管值）
(function() {
    "use strict";
    if (window.__desireVideoSpeed) return;
    window.__desireVideoSpeed = (function () {
        var rate = 1;
        var badgeTimer = null;

        function applyAll() {
            document.querySelectorAll('video, audio').forEach(function (m) {
                try {
                    m.preservesPitch = true;
                    m.playbackRate = rate;
                } catch (e) { /* 元素竞态静默 */ }
            });
        }

        function badge() {
            if (rate === 1) { removeBadge(); return; }
            var b = document.getElementById('__desireSpeedBadge');
            if (!b) {
                b = document.createElement('div');
                b.id = '__desireSpeedBadge';
                b.style.cssText = 'position:fixed;right:14px;bottom:14px;z-index:2147483646;' +
                    'background:rgba(20,20,20,.85);color:#fff;font:600 12px -apple-system;' +
                    'padding:4px 10px;border-radius:12px;pointer-events:none;transition:opacity .6s;';
                (document.body || document.documentElement).appendChild(b);
            }
            b.textContent = rate + '×';
            b.style.opacity = '1';
            if (badgeTimer) clearTimeout(badgeTimer);
            badgeTimer = setTimeout(function () { b.style.opacity = '0'; }, 8000);
        }

        function removeBadge() {
            var b = document.getElementById('__desireSpeedBadge');
            if (b) b.remove();
        }

        function set(r) {
            rate = Math.min(3, Math.max(0.25, r));
            applyAll();
            badge();
        }

        new MutationObserver(applyAll).observe(document.documentElement, { childList: true, subtree: true });
        document.addEventListener('DOMContentLoaded', applyAll);
        return { set: set, get: function () { return rate; } };
    })();
})();
