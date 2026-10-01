// anti-adblock.js — 反"反广告拦截"（随"拦截视频广告"开关注入，主框架 atDocumentEnd）
//
// 套路：站点检测到广告被拦后拒绝服务——"请关闭广告拦截器"弹层盖住正文，
// 或用 bait 元素（.adsbox 等故意命名的假广告位）的 offsetHeight 判定拦截器存在。
//
// 对策（都是被动防御，不主动攻击站点逻辑）：
//   ① bait 元素伪装：给常见 bait 类名的元素补 1px 透明占位——拦截器把它们
//      display:none 后，检测 JS 读 offsetHeight 得到 1 而不是 0，判定"广告正常加载"；
//   ② 反拦截提示层隐藏：常见命名的"检测到广告拦截器"覆盖层直接不渲染；
//   ③ 窗口级钩子兜底：部分站点把检测结果写进全局变量供后续逻辑用——hook 不可行
//      （无法枚举），放弃；①+② 已覆盖主流实现（AdblockPlus 检测范式）。
//
// 只在检测到**确认特征**时动作，误伤面极小。
(function() {
    if (window.__desireAntiAdblock) return;
    window.__desireAntiAdblock = true;

    var BAIT_SELECTORS = [
        '.adsbox', '.ad-placeholder', '.ad-banner-wrapper', '.adBANNER',
        '#ad-banner', '.text-ad', '.ad-slot', '#adslot', '.adzone',
        'ins.adsbygoogle'
    ];
    var NOTICE_SELECTORS = [
        '[class*="adblock-detected" i]', '[id*="adblock-detected" i]',
        '[class*="adblock-notice" i]', '[id*="adblock-notice" i]',
        '[class*="anti-adblock" i]', '[class*="adblock-msg" i]',
        '[class*="adblocker" i][class*="detect" i]',
        '[id*="adblock" i][class*="warning" i]'
    ];

    // ① bait 元素伪装成"已加载"：1×1 透明、不被 display:none 完全清零。
    function disguiseBaits() {
        var patched = 0;
        for (var i = 0; i < BAIT_SELECTORS.length; i++) {
            var els = document.querySelectorAll(BAIT_SELECTORS[i]);
            for (var j = 0; j < els.length; j++) {
                var el = els[j];
                if (el.getAttribute('data-desire-bait') === '1') continue;
                el.setAttribute('data-desire-bait', '1');
                el.style.setProperty('display', 'block', 'important');
                el.style.setProperty('height', '1px', 'important');
                el.style.setProperty('width', '1px', 'important');
                el.style.setProperty('opacity', '0', 'important');
                el.style.setProperty('pointer-events', 'none', 'important');
                patched++;
            }
        }
        return patched;
    }

    // ② 反拦截提示层不渲染。
    function hideNotices() {
        var hidden = 0;
        for (var i = 0; i < NOTICE_SELECTORS.length; i++) {
            var els = document.querySelectorAll(NOTICE_SELECTORS[i]);
            for (var j = 0; j < els.length; j++) {
                var el = els[j];
                if (el.getAttribute('data-desire-notice') === '1') continue;
                el.setAttribute('data-desire-notice', '1');
                el.style.setProperty('display', 'none', 'important');
                hidden++;
            }
        }
        return hidden;
    }

    function pass() {
        var a = disguiseBaits();
        var b = hideNotices();
        if ((a || b) && window.webkit && window.webkit.messageHandlers &&
            window.webkit.messageHandlers.videoAdBlocked) {
            window.webkit.messageHandlers.videoAdBlocked.postMessage({
                count: a + b, site: location.hostname, action: 'anti-adblock'
            });
        }
    }

    // DOM 就绪先过一遍；动态插入的（检测库延迟建弹层）用 MutationObserver 兜底。
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', pass);
    } else {
        pass();
    }
    var mo = new MutationObserver(function() { pass(); });
    function armObserver() {
        if (document.body) {
            mo.observe(document.body, { childList: true, subtree: true });
        } else {
            setTimeout(armObserver, 50);
        }
    }
    armObserver();
})();
