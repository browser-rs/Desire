// super-drag.js — 超级拖拽（0.7.13，默认关）：在链接上按下左键时上报 URL 给宿主，
// 宿主在 mouseUp 判定"拖动超阈值"后开后台标签。只上报不拦截——点击/中键行为不变。
(function() {
    if (window.__desireSuperDrag) return;
    window.__desireSuperDrag = true;

    function linkURL(anchor) {
        if (!anchor) return null;
        try {
            var href = anchor.href;   // href 属性解析为绝对 URL
            return (href && href.startsWith('http')) ? href : null;
        } catch (e) { return null; }
    }

    document.addEventListener('mousedown', function(e) {
        if (e.button !== 0) return;
        var el = e.target;
        // 向上找最近的链接（含 YouTube 等把 <a> 包在卡片里的形态）
        var anchor = el && el.closest ? el.closest('a[href]') : null;
        if (anchor) {
            var url = linkURL(anchor);
            if (url) {
                try {
                    window.webkit.messageHandlers.superDragLink.postMessage({ url: url, x: e.screenX, y: e.screenY });
                } catch (err) {}
                return;
            }
        }
        try {
            window.webkit.messageHandlers.superDragLink.postMessage({ url: null });
        } catch (err) {}
    }, true);
})();
