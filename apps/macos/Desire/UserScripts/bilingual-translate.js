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
    // 块 id → inline code 原始 HTML 列表（collect 时生成、apply 时还原）。
    var codeMap = {};

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
            // inline code 占位保护（v0.8.62 批 2）：块内 <code> 替换成 ⟦N⟧
            // 占位符再提取文本——术语/变量名不被机翻弄坏；映射存 codeMap，
            // apply 时按占位符还原成原 code 的 HTML。
            var clone = el.cloneNode(true);
            var codes = [];
            var codeNodes = clone.querySelectorAll('code');
            for (var c = 0; c < codeNodes.length; c++) {
                codes.push(codeNodes[c].outerHTML);
                codeNodes[c].textContent = '\u27E6' + c + '\u27E7';
            }
            var text = (clone.textContent || '').trim().replace(/\s+/g, ' ');
            if (text.length < 12) continue;
            if (text.length > 1200) text = text.slice(0, 1200);
            if (used + text.length > maxChars) break;
            if (!visible(el)) continue;
            var id = el.getAttribute('data-desire-bi');
            if (id === null || id === '') {
                id = String(nextId++);
                el.setAttribute('data-desire-bi', id);
            }
            if (codes.length) codeMap[id] = codes;
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
            // inline code 还原：译文里的 ⟦N⟧ 占位符换回原始 <code> HTML
            // （collect 时生成的 codeMap[id]；找不到映射/占位符时译文原样保留）。
            // **安全**：译文来自模型（可能被页面内容注入诱导），先整段 HTML
            // 转义再还原占位符——占位符本身用转义安全的 ⟦N⟧ 字符。
            var codes = codeMap[it.id];
            var translated = it.text
                .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
            if (codes && codes.length) {
                translated = translated.replace(/\u27E6(\d+)\u27E7/g, function (_, n) {
                    var idx = parseInt(n, 10);
                    return (idx >= 0 && idx < codes.length) ? codes[idx] : '';
                });
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
            // 占位符已还原成 <code> HTML → 用 innerHTML 而非 textContent
            node.innerHTML = translated;
            node.setAttribute('data-desire-bi-for', it.id);
            applied++;
        }
        return applied;
    };

    // 双语导出（v0.8.62）：收集已翻译的 (原文, 译文) 对——宿主组 Markdown
    // 存档。只返回有译文的对（翻译未完成的块跳过）。
    window.__desireBilingualExport = function() {
        var nodes = document.querySelectorAll('[data-desire-bi]');
        var out = [];
        for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            var original = (el.innerText || '').trim();
            if (!original) continue;
            var tNode = null;
            var inside = INSIDE[el.tagName] === 1;
            if (inside) tNode = el.querySelector(':scope > .' + CLASS);
            else if (el.nextElementSibling && el.nextElementSibling.classList
                     && el.nextElementSibling.classList.contains(CLASS)) tNode = el.nextElementSibling;
            var translation = tNode ? (tNode.innerText || '').trim() : '';
            if (!translation) continue;
            out.push({ original: original, translation: translation });
        }
        return out;
    };

    // 替换式（v0.8.8 自研整页翻译）：原文挂在节点属性上（节点存活期间可
    // 完整还原——不用 data- 属性，避免超长文本/引号转义问题）。
    window.__desireBilingualReplace = function(items) {
        if (!items || !items.length) return 0;
        var applied = 0;
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            var el = document.querySelector('[data-desire-bi="' + it.id + '"]');
            if (!el) continue;
            // 原文保存 innerHTML（还原时连 <code>/<a>/<b> 一起回来；
            // 只存 textContent 会把行内代码等格式永久抹掉）。
            if (el.__desireOrig === undefined) el.__desireOrig = el.innerHTML;
            // inline code 占位还原（v0.8.80 批 5，S1）：替换式此前直接
            // textContent = it.text，页面正文出现 ⟦N⟧ 乱码。与对照式同一套：
            // 先整段 HTML 转义，再把 ⟦N⟧ 换回 collect 时的原始 code HTML。
            var codes = codeMap[it.id];
            if (codes && codes.length && it.text.indexOf('\u27E6') >= 0) {
                var safe = it.text
                    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                    .replace(/"/g, '&quot;').replace(/'/g, '&#39;')
                    .replace(/\u27E6(\d+)\u27E7/g, function (_, n) {
                        var idx = parseInt(n, 10);
                        return (idx >= 0 && idx < codes.length) ? codes[idx] : '';
                    });
                el.innerHTML = safe;
            } else {
                el.textContent = it.text;
            }
            el.setAttribute('data-desire-bi-replaced', '1');
            applied++;
        }
        return applied;
    };

    // 还原替换式的原文（对照式的清除走 clear）。
    window.__desireBilingualRestore = function() {
        var nodes = document.querySelectorAll('[data-desire-bi-replaced]');
        for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            if (el.__desireOrig !== undefined) el.innerHTML = el.__desireOrig;
            el.removeAttribute('data-desire-bi-replaced');
        }
        return nodes.length;
    };

    window.__desireBilingualClear = function() {
        window.__desireBilingualRestore();
        var nodes = document.querySelectorAll('.' + CLASS);
        for (var i = 0; i < nodes.length; i++) nodes[i].remove();
        var marked = document.querySelectorAll('[data-desire-bi]');
        for (var j = 0; j < marked.length; j++) marked[j].removeAttribute('data-desire-bi');
        return nodes.length;
    };
})();
