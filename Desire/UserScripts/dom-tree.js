// dom-tree.js — Element 页签的 DOM 树数据源（按需展开，一次一层）。
//
// 用法：`callAsyncJavaScript(script, arguments: ["path": "0/2", "maxChildren": 200])`
// —— 形参名必须与字典键一致（见 AGENTS.md 的 callAsyncJavaScript 约定）。
//
// path 是 **nth-child 链**："" = <html>；"0" = <html> 的第 1 个子元素；
// "0/2" = 那个子元素的第 3 个子元素。用链而不是选择器，是因为链在
// 结构变化前始终唯一，且不需要给页面加标记。
//
// 返回 JSON：根节点信息 + 直接子节点（每个子节点带 tag/id/class/子数/文本
// 预览/可直接用于 inspect 的 nth-child 选择器）。
return (function() {
    function elementAt(chain) {
        var el = document.documentElement;
        if (!chain) return el;
        var parts = String(chain).split('/').filter(function(part) { return part.length > 0; });
        for (var i = 0; i < parts.length; i++) {
            var index = parseInt(parts[i], 10);
            var kids = el.children;
            if (!kids || isNaN(index) || index < 0 || index >= kids.length) return null;
            el = kids[index];
        }
        return el;
    }

    // nth-child 链选择器（选中树节点后走既有的 element-inspect 采集）。
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
        return 'html' + (parts.length ? ' > ' + parts.join(' > ') : '');
    }

    function textPreview(el) {
        var text = '';
        for (var i = 0; i < el.childNodes.length; i++) {
            var node = el.childNodes[i];
            if (node.nodeType === 3 && node.nodeValue && node.nodeValue.trim()) {
                text += node.nodeValue.trim() + ' ';
            }
            if (text.length > 60) break;
        }
        return text ? text.slice(0, 60).trim() : null;
    }

    function describe(el, path) {
        var classes = [];
        try { classes = Array.prototype.slice.call(el.classList || []).slice(0, 4); } catch (e) {}
        return {
            path: path,
            tag: el.tagName ? el.tagName.toLowerCase() : '#text',
            id: el.id || null,
            classes: classes,
            childCount: el.children ? el.children.length : 0,
            text: textPreview(el),
            selector: selectorFor(el)
        };
    }

    var root = elementAt(path);
    if (!root) return JSON.stringify({ error: 'not found' });

    var children = [];
    var kids = root.children || [];
    var limit = Math.max(1, Math.min(maxChildren || 200, 500));
    for (var i = 0; i < kids.length && i < limit; i++) {
        children.push(describe(kids[i], (path ? path + '/' : '') + i));
    }
    return JSON.stringify({
        path: path || '',
        tag: root.tagName ? root.tagName.toLowerCase() : '#document',
        id: root.id || null,
        classes: Array.prototype.slice.call(root.classList || []).slice(0, 4),
        childCount: kids.length,
        truncated: kids.length > limit,
        selector: selectorFor(root),
        children: children
    });
})();
