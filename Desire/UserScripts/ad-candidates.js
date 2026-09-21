// ad-candidates.js — 广告候选元素识别（Coding with AI 的第 2 步：让模型有的放矢）。
//
// 用法：`callAsyncJavaScript(script, arguments: ["limit": 25])`，返回 JSON 字符串。
// 纯启发式打分（**不做删除**，只给候选 + 理由），由模型/用户决定屏蔽哪些，
// 真正的屏蔽走 `blockElements` 工具（ElementBlockStore + 立即注入 CSS）。
return (function() {
    var AD_TOKENS = /(^|[-_ ])(ad|ads|advert|advertisement|adsbygoogle|sponsor|sponsored|promo|promoted|banner|popup|overlay|interstitial|dfp|gpt)([-_ ]|$)/i;
    var AD_HOSTS = /(doubleclick|googlesyndication|googleadservices|adservice|adsystem|criteo|taboola|outbrain|pubmatic|rubicon|openx|smartadserver|amazon-adsystem|adnxs|teads|mgid)/i;
    var AD_LABELS = /^(ad|ads|广告|赞助|贊助|sponsored|promoted|sponsored content|推广|推廣|advertisement)$/i;
    var SLOT_SIZES = [[300, 250], [336, 280], [728, 90], [970, 90], [970, 250], [160, 600], [300, 600], [320, 50], [320, 100], [468, 60], [250, 250], [120, 600]];

    function selectorFor(el) {
        var parts = [];
        var node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
            var parent = node.parentElement;
            if (!parent) break;
            var index = Array.prototype.indexOf.call(parent.children, node) + 1;
            parts.unshift(node.tagName.toLowerCase() + ':nth-child(' + index + ')');
            node = parent;
        }
        return parts.length ? 'html > ' + parts.join(' > ') : 'html';
    }

    function sizeOf(el) {
        var rect = el.getBoundingClientRect();
        return { w: Math.round(rect.width), h: Math.round(rect.height), area: Math.round(rect.width * rect.height) };
    }

    function isSlotSize(size) {
        for (var i = 0; i < SLOT_SIZES.length; i++) {
            var slot = SLOT_SIZES[i];
            if (Math.abs(size.w - slot[0]) <= slot[0] * 0.12 && Math.abs(size.h - slot[1]) <= slot[1] * 0.12) return true;
        }
        return false;
    }

    function looksLikeAd(el, size) {
        var reasons = [];
        var style = getComputedStyle(el);
        var identity = ((typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || ''));
        if (AD_TOKENS.test(identity)) reasons.push('class/id');

        if (el.tagName === 'IFRAME') {
            var src = el.getAttribute('src') || '';
            if (AD_HOSTS.test(src)) reasons.push('iframe:ad-host');
            else if (src && /^https?:/i.test(src)) {
                try { if (new URL(src, location.href).host !== location.host) reasons.push('iframe:cross-origin'); } catch (e) {}
            }
        }

        var link = el.querySelector && el.querySelector('a[href]');
        if (link && AD_HOSTS.test(link.getAttribute('href') || '')) reasons.push('link:ad-host');

        var zIndex = parseInt(style.zIndex, 10);
        if ((style.position === 'fixed' || style.position === 'absolute') && zIndex >= 1000) {
            reasons.push('overlay:z' + zIndex);
        }

        if (isSlotSize(size)) reasons.push('slot-size');

        var label = (el.textContent || '').trim().slice(0, 40);
        if (AD_LABELS.test(label)) reasons.push('label');

        // 容器里含 iframe 且尺寸像广告位（页脚/侧栏常见形态）。
        if (!reasons.length && el.querySelector && el.querySelector('iframe')
            && size.w >= 200 && size.h >= 100 && size.area < 400000) {
            reasons.push('iframe-in-block');
        }
        return reasons;
    }

    var limit = typeof maxItems === 'undefined' ? 25 : maxItems;
    var candidates = [];
    var all = document.body ? document.body.querySelectorAll('*') : [];
    for (var i = 0; i < all.length; i++) {
        var el = all[i];
        // 只看到一定深度，避免整棵树扫一遍拖慢页面。
        var depth = 0;
        for (var node = el; node && node !== document.body; node = node.parentElement) depth++;
        if (depth > 12) continue;
        var size = sizeOf(el);
        if (size.w < 40 || size.h < 20) continue;
        var reasons = looksLikeAd(el, size);
        if (!reasons.length) continue;
        candidates.push({
            selector: selectorFor(el),
            tag: el.tagName.toLowerCase(),
            width: size.w,
            height: size.h,
            area: size.area,
            reasons: reasons,
            text: (el.textContent || '').trim().slice(0, 60),
            src: el.tagName === 'IFRAME' ? (new URL(el.getAttribute('src') || 'about:blank', location.href).href) : null
        });
    }
    candidates.sort(function(a, b) { return b.reasons.length - a.reasons.length || b.area - a.area; });
    return JSON.stringify({
        url: location.href,
        scanned: all.length,
        total: candidates.length,
        candidates: candidates.slice(0, Math.max(1, Math.min(limit, 60)))
    });
})();
