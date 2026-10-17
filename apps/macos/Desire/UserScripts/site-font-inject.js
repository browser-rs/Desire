// site-font-inject.js
// 站点字体注入（最小字号 + 字体族）。由 SiteFontApplier 以
// `window.__desireSiteFontCfg = {min, family}` 先行注入配置后一次求值。
//
// 幂等：重复调用按新配置重设，含"关闭"。两块实现语义（勿混）：
//   - 字体族：一条 html/body 的样式（**无 !important**）——只作默认族，
//     网页自身指定的字体照样赢（浏览器"标准字体"同语义；图标字体不受损）。
//   - 最小字号：CSS 没有 min-font-size，逐元素把计算字号不足下限的元素
//     以内联 !important 抬到下限。**覆盖前先把原内联值存进 data 属性**、
//     还原时原样写回——直接 removeProperty 会连网页自己的内联字号一起
//     毁掉（实测：10px 内联被抬升后再还原 ⇒ 掉到默认 16px，原值丢失）。
//     MutationObserver 去抖复扫，覆盖懒加载/SPA 重渲染；复扫时"已标记"
//     元素按**保存的原值**决定去留（按 computed 判断会读到自己设的
//     !important，把仍在生效的抬升误判成"已经够大"而自毁）。
(function() {
    var cfg = window.__desireSiteFontCfg || { min: 0, family: "" };
    try { delete window.__desireSiteFontCfg; } catch (e) { window.__desireSiteFontCfg = null; }

    var STYLE_ID = 'desire-site-font-family';
    var MARK = 'data-desire-minfont';

    // 字体族：只作默认族（html/body、无 !important），网页自身字体照样赢。
    var style = document.getElementById(STYLE_ID);
    if (cfg.family) {
        if (!style) {
            style = document.createElement('style');
            style.id = STYLE_ID;
            (document.head || document.documentElement).appendChild(style);
        }
        style.textContent = 'html, body { font-family: ' + JSON.stringify(cfg.family) + ', sans-serif; }';
    } else if (style) {
        style.remove();
    }

    function hasOwnText(el) {
        for (var n = el.firstChild; n; n = n.nextSibling) {
            if (n.nodeType === 3 && /\S/.test(n.nodeValue || '')) return true;
        }
        return false;
    }

    // 还原一次抬升：原值（可能带 !important 后缀 '!' 的标记）原样写回。
    function restore(el) {
        var saved = el.getAttribute(MARK) || '';
        el.removeAttribute(MARK);
        if (!saved) { el.style.removeProperty('font-size'); return; }
        var important = saved.charAt(saved.length - 1) === '!';
        var value = important ? saved.slice(0, -1) : saved;
        if (value) {
            el.style.setProperty('font-size', value, important ? 'important' : '');
        } else {
            el.style.removeProperty('font-size');
        }
    }

    // 先整体还原上一代注入，再按新配置重扫（下限调大/调小都从原值出发）。
    var stale = document.querySelectorAll('[' + MARK + ']');
    for (var si = 0; si < stale.length; si++) restore(stale[si]);

    function bump() {
        var min = window.__desireSiteFontMin || 0;
        var els;
        try { els = document.querySelectorAll('*'); } catch (e) { return; }
        for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var marked = el.hasAttribute && el.hasAttribute(MARK);
            if (!hasOwnText(el)) {
                if (marked) restore(el);
                continue;
            }
            if (!min) {
                if (marked) restore(el);
                continue;
            }
            if (marked) {
                // 已抬升：按保存的原值判断是否还需要抬（原值缺省/仍低于下限
                // 就继续压住，否则还原）。不能看 computed——那是我们自己的值。
                var savedSize = parseFloat(el.getAttribute(MARK)) || 0;
                if (savedSize > 0 && savedSize >= min) restore(el);
                else el.style.setProperty('font-size', min + 'px', 'important');
                continue;
            }
            var size = 0;
            try { size = parseFloat(getComputedStyle(el).fontSize) || 0; } catch (e) {}
            if (size > 0 && size < min) {
                el.setAttribute(MARK, el.style.getPropertyValue('font-size')
                    + (el.style.getPropertyPriority('font-size') ? '!' : ''));
                el.style.setProperty('font-size', min + 'px', 'important');
            }
        }
    }

    window.__desireSiteFontMin = cfg.min || 0;

    // MutationObserver 单例：重挂前先断开（否则重注入会叠加多份观察器）。
    if (window.__desireSiteFontObserver) {
        try { window.__desireSiteFontObserver.disconnect(); } catch (e) {}
        window.__desireSiteFontObserver = null;
    }
    if (window.__desireSiteFontMin > 0) {
        var pending = null;
        var observer = new MutationObserver(function() {
            if (pending) return;
            pending = setTimeout(function() { pending = null; bump(); }, 250);
        });
        try {
            observer.observe(document.documentElement, { childList: true, subtree: true });
            window.__desireSiteFontObserver = observer;
        } catch (e) {}
    }

    bump();
})();
