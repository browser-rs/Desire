// bilingual-translate.js
// 双语对照（AI 翻译）的页面侧。主机侧（BilingualReadingService）通过
// window.__desireBilingual* 三个入口调用：
//   collect({maxBlocks,maxChars}) -> {blocks:[{id,text}]}  收集块级文本
//   apply([{id,text}])            -> 译文插到对应块后（可多批）
//   clear()                       -> 移除全部译文与标记
// 幂等安装；块用 data-desire-bi 标 id（重跑复用、clear 时清除）。
(function() {
    if (window.__desireBilingualInstalled) return;
    window.__desireBilingualInstalled = true;

    var BLOCK_SELECTOR = 'p, li, h1, h2, h3, h4, h5, h6, blockquote, td, dd, figcaption';
    var CLASS = 'desire-bilingual';
    // 译文节点挂在这些块**内部**（表格/列表里插入兄弟块会破坏表格/列表结构），
    // 其余挂在块后。
    var INSIDE = { LI: 1, TD: 1, DD: 1, FIGCAPTION: 1 };

    function visible(el) {
        var r = el.getBoundingClientRect && el.getBoundingClientRect();
        if (!r || r.width < 8 || r.height < 4) return false;
        var st = getComputedStyle(el);
        return st.display !== 'none' && st.visibility !== 'hidden';
    }

    window.__desireBilingualCollect = function(opts) {
        opts = opts || {};
        var maxBlocks = opts.maxBlocks || 60;
        var maxChars = opts.maxChars || 15000;
        var out = [];
        var used = 0;
        var nextId = 0;
        var existing = document.querySelectorAll('[data-desire-bi]');
        for (var e = 0; e < existing.length; e++) {
            var n = parseInt(existing[e].getAttribute('data-desire-bi'), 10);
            if (!isNaN(n) && n >= nextId) nextId = n + 1;
        }
        var els = document.querySelectorAll(BLOCK_SELECTOR);
        for (var i = 0; i < els.length && out.length < maxBlocks; i++) {
            var el = els[i];
            if (el.closest && el.closest('.' + CLASS)) continue;
            var text = (el.innerText || el.textContent || '').trim().replace(/\s+/g, ' ');
            if (text.length < 12) continue;
            if (text.length > 1200) text = text.slice(0, 1200);
            if (used + text.length > maxChars) break;
            if (!visible(el)) continue;
            var id = el.getAttribute('data-desire-bi');
            if (id === null || id === '') {
                id = String(nextId++);
                el.setAttribute('data-desire-bi', id);
            }
            used += text.length;
            out.push({ id: id, text: text });
        }
        return { blocks: out };
    };

    window.__desireBilingualApply = function(items) {
        if (!items || !items.length) return 0;
        var applied = 0;
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            var el = document.querySelector('[data-desire-bi="' + it.id + '"]');
            if (!el) continue;
            var inside = INSIDE[el.tagName] === 1;
            var node = null;
            if (inside) {
                node = el.querySelector(':scope > .' + CLASS);
            } else if (el.nextElementSibling && el.nextElementSibling.classList
                       && el.nextElementSibling.classList.contains(CLASS)) {
                node = el.nextElementSibling;
            }
            if (!node) {
                node = document.createElement('div');
                node.className = CLASS;
                node.style.cssText =
                    'margin:2px 0 10px;padding:2px 0 2px 10px;'
                    + 'border-left:3px solid rgba(128,128,128,.45);'
                    + 'opacity:.86;white-space:normal;';
                if (inside) {
                    el.appendChild(node);
                } else {
                    el.parentNode.insertBefore(node, el.nextSibling);
                }
            }
            node.textContent = it.text;
            node.setAttribute('data-desire-bi-for', it.id);
            applied++;
        }
        return applied;
    };

    window.__desireBilingualClear = function() {
        var nodes = document.querySelectorAll('.' + CLASS);
        for (var i = 0; i < nodes.length; i++) nodes[i].remove();
        var marked = document.querySelectorAll('[data-desire-bi]');
        for (var j = 0; j < marked.length; j++) marked[j].removeAttribute('data-desire-bi');
        return nodes.length;
    };
})();
