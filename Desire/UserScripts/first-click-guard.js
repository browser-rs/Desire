// first-click-guard.js — 首次点击劫持防护（视频页通用，随"拦截视频广告"开关注入）
//
// 套路：播放按钮上盖一层透明层（`<a target="_blank" href="广告">` 或带 click 处理器
// 的浮层），第一次点击不播放，而是弹广告窗口 / 跳广告页。多见于影视站、聚合站。
//
// 策略（**只作用于首次点击**，且只在页面里存在 `<video>` 时生效）：
//   ① 这次点击期间临时禁掉 `window.open`——脚本弹窗直接失效（1.2s 后恢复）；
//   ② 若首次点击落在"站外链接"或"覆盖全屏的浮层"上，吞掉这次点击并隐藏该元素，
//      让用户的下一次点击落到真正的播放控件；
//   ③ 把拦下的目标报给原生（`videoAdBlocked`），面板/提示可见、也便于按站微调。
//
// 不做的：站内链接、播放器自身的控件、以及第二次以后的点击一概不干预。
(function() {
    if (window.__desireFirstClickGuard) return;
    window.__desireFirstClickGuard = true;

    function post(payload) {
        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoAdBlocked) {
                window.webkit.messageHandlers.videoAdBlocked.postMessage(payload);
            }
        } catch (e) {}
    }

    function hostOf(url) {
        try { return new URL(url, location.href).hostname.replace(/^www\./, '').toLowerCase(); } catch (e) { return ''; }
    }

    function sameSite(a, b) {
        var ha = hostOf(a), hb = hostOf(b);
        if (!ha || !hb) return true;
        if (ha === hb) return true;
        return ha.slice(-(hb.length + 1)) === '.' + hb || hb.slice(-(ha.length + 1)) === '.' + ha;
    }

    /// 往上找"定位祖先"（覆盖层的典型特征）。
    function positionedAncestor(el) {
        var node = el;
        var hops = 0;
        while (node && node !== document.body && hops < 5) {
            var style = getComputedStyle(node);
            if (style.position === 'absolute' || style.position === 'fixed' || style.position === 'sticky') return node;
            node = node.parentElement;
            hops++;
        }
        return null;
    }

    /// 浮层判据：定位 + 覆盖视口相当比例 + 不在播放器里面。
    function looksLikeOverlay(el, player) {
        if (!el || !player) return false;
        if (player.contains(el)) return false;              // 播放器自己的控件不算
        var layer = positionedAncestor(el);
        if (!layer) return false;
        if (player.contains(layer)) return false;
        var rect = layer.getBoundingClientRect();
        var area = rect.width * rect.height;
        var viewport = window.innerWidth * window.innerHeight;
        if (viewport <= 0) return false;
        if (area / viewport < 0.25) return false;
        var style = getComputedStyle(layer);
        var z = parseInt(style.zIndex, 10);
        return !isNaN(z) ? z >= 100 : true;
    }

    var handled = false;

    document.addEventListener('click', function(event) {
        if (handled) return;
        // 只在视频页生效：没有 <video> 的页面完全不干预（避免影响正常浏览）。
        var player = document.querySelector('video');
        if (!player) return;
        handled = true;

        // ① 首次点击期间禁掉脚本弹窗。
        var originalOpen = window.open;
        window.open = function() { return null; };
        setTimeout(function() { window.open = originalOpen; }, 1200);

        var target = event.target;
        if (!target || !target.closest) return;

        var anchor = target.closest('a[href]');
        var offsiteAnchor = anchor && /^https?:/i.test(anchor.href || '') && !sameSite(anchor.href, location.href);
        var overlay = looksLikeOverlay(target, player);

        if (!offsiteAnchor && !overlay) return;   // 正常点击（含播放键）：不拦

        event.preventDefault();
        event.stopImmediatePropagation();

        var layer = positionedAncestor(anchor || target) || anchor || target;
        try { layer.style.setProperty('display', 'none', 'important'); } catch (e) {}
        post({
            count: 1,
            site: location.hostname,
            action: 'click-hijack',
            url: (anchor && anchor.href) || ''
        });
    }, true);
})();
