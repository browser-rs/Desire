// element-inspect.js
// 用法：`evaluateJavaScript` 调用，把 SELECTOR 换成选择器字面量后执行。
// 返回 JSON 字符串（`InspectedElement` 的形状）：DevTools ▸ Element 页签的数据源。
//
// 这段逻辑原来只存在于 DevTools/ElementInspector.swift 的 #Preview 里（那个文件
// 只被自己的预览引用），线上的 Element 页签因此从来没有被填过——本脚本把这条线
// 接上（见 DevToolsStore.inspectElement(selector:in:)）。
(function() {
    var el = document.querySelector('__SELECTOR__');
    if (!el) return null;

    var computed = getComputedStyle(el);
    // 挑一组排查真正常看的计算属性（全量 dump 有 300+ 条，面板里没法看）。
    var keys = [
        'display', 'position', 'top', 'right', 'bottom', 'left',
        'width', 'height', 'margin', 'padding', 'box-sizing',
        'flex-direction', 'justify-content', 'align-items', 'gap',
        'grid-template-columns', 'grid-template-rows',
        'color', 'background-color', 'background-image',
        'font-family', 'font-size', 'font-weight', 'line-height', 'text-align',
        'border', 'border-radius', 'box-shadow', 'opacity',
        'transform', 'transition', 'overflow', 'visibility', 'z-index'
    ];
    var computedStyle = {};
    keys.forEach(function(key) { computedStyle[key] = computed.getPropertyValue(key); });

    // 内联样式（作者的意图）单独列，带 !important 标记。
    var cssProperties = [];
    for (var i = 0; i < el.style.length; i++) {
        var name = el.style[i];
        cssProperties.push({
            name: name,
            value: el.style.getPropertyValue(name),
            important: el.style.getPropertyPriority(name) === 'important',
            source: null
        });
    }

    var attributes = {};
    for (var a = 0; a < el.attributes.length; a++) {
        attributes[el.attributes[a].name] = el.attributes[a].value;
    }

    var tag = el.tagName.toLowerCase();
    var selector = el.id ? '#' + CSS.escape(el.id) : tag;
    if (!el.id && el.classList.length) {
        selector = tag + Array.from(el.classList).map(function(c) { return '.' + CSS.escape(c); }).join('');
    }

    // 到根的完整 CSS 路径（每段带 nth-child，唯一可定位）。
    function cssPathOf(node) {
        var parts = [];
        while (node && node.nodeType === 1 && node !== document.documentElement) {
            var part = node.tagName.toLowerCase();
            var parent = node.parentElement;
            if (parent) {
                var sameTag = Array.prototype.filter.call(parent.children, function(c) { return c.tagName === node.tagName; });
                if (sameTag.length > 1) part += ':nth-child(' + (Array.prototype.indexOf.call(parent.children, node) + 1) + ')';
            }
            parts.unshift(part);
            node = parent;
        }
        return 'html>' + parts.join('>');
    }

    // 命中的 CSS 规则（级联排查）：作者样式表里能匹配上这个元素的选择器及其声明。
    // 跨域样式表读 cssRules 会抛 SecurityError——跳过并计数，面板里说明
    // "N 张跨域样式表未读"，免得让人以为规则丢了。
    var matchingRules = [];
    var crossOriginSheets = 0;
    try {
        var sheets = document.styleSheets;
        for (var s = 0; s < sheets.length && matchingRules.length < 40; s++) {
            var list = null;
            try { list = sheets[s].cssRules; } catch (e) { crossOriginSheets++; continue; }
            if (!list) continue;
            for (var r = 0; r < list.length && matchingRules.length < 40; r++) {
                var rule = list[r];
                if (!rule.selectorText) continue;
                var matched = false;
                try { matched = el.matches(rule.selectorText); } catch (e) { matched = false; }
                if (!matched) continue;
                matchingRules.push({
                    selector: rule.selectorText,
                    css: rule.style && rule.style.cssText ? rule.style.cssText.slice(0, 600) : ''
                });
            }
        }
    } catch (e) {}

    var rect = el.getBoundingClientRect();
    return JSON.stringify({
        tagName: tag,
        attributes: attributes,
        innerHTML: (el.innerHTML || '').slice(0, 4000),
        outerHTML: (el.outerHTML || '').slice(0, 8000),
        cssProperties: cssProperties,
        computedStyle: computedStyle,
        boundingBox: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
        selector: selector,
        cssPath: cssPathOf(el),
        xpath: null,
        matchingRules: matchingRules,
        crossOriginSheets: crossOriginSheets
    });
})();
