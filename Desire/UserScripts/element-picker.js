// element-picker.js
// Source: Desire/Features/Browsing/WebView.swift (WebView.pickerJS)
// Injected as: one-shot evaluateJavaScript (from ContentView when entering
// element-block or AI element-pick mode).
// Injects a highlight style, builds a stable CSS selector + XPath for the
// clicked element, and posts both to the `elementPicker` handler.
(function() {
    // P0（第三轮补修）：exit 脚本只删 style 不摘监听器——取消拾取后
    // ① capture click 永久吞点击 ② removeChild(style) 抛 NotFoundError。
    // 修复方案：teardown 挂到 window（exit 脚本可调用），onPick 用
    // getElementById 判空（不再抛），重复注入先 teardown 旧的。
    if (window.__desirePickerTeardown) window.__desirePickerTeardown();

    var style = document.createElement('style');
    style.id = 'desire-picker-style';
    style.textContent = '.desire-picker-highlight{outline:3px solid #ff4444 !important;outline-offset:-1px !important;background:rgba(255,68,68,0.08) !important;cursor:crosshair !important}';
    document.head.appendChild(style);

    var hl;

    function getSelector(el) {
        if (el.id) return '#' + CSS.escape(el.id);
        var parts = [];
        while (el && el.nodeType === 1) {
            var tag = el.tagName.toLowerCase();
            if (el.id) { parts.unshift('#' + CSS.escape(el.id)); break; }
            var p = el.parentElement;
            if (p) {
                var ch = Array.from(p.children);
                var idx = ch.indexOf(el);
                var same = ch.filter(function(c) { return c.tagName === el.tagName; });
                if (same.length > 1) tag += ':nth-child(' + (idx + 1) + ')';
            }
            parts.unshift(tag);
            el = p;
        }
        return parts.join(' > ');
    }

    function getXPath(el) {
        if (el.id) return '//*[@id="' + el.id + '"]';
        var parts = [];
        while (el && el.nodeType === 1) {
            var tag = el.tagName.toLowerCase();
            if (el.id) { parts.unshift('*[@id="' + el.id + '"]'); break; }
            var p = el.parentElement;
            if (p) {
                var ch = Array.from(p.children);
                var idx = Array.prototype.indexOf.call(p.children, el) + 1;
                tag += '[' + idx + ']';
            }
            parts.unshift(tag);
            el = p;
        }
        return '/' + parts.join('/');
    }

    function onOver(e) { if (hl) hl.classList.remove('desire-picker-highlight'); hl = e.target; hl.classList.add('desire-picker-highlight'); e.stopPropagation(); }
    function onOut(e) { if (hl) hl.classList.remove('desire-picker-highlight'); hl = null; e.stopPropagation(); }
    function onPick(e) {
        e.preventDefault(); e.stopPropagation();
        if (hl) hl.classList.remove('desire-picker-highlight');
        var sel = getSelector(e.target), xp = getXPath(e.target);
        // 用 getElementById 判空后再删——exit 脚本可能已删掉 style，
        // removeChild 对已删节点抛 NotFoundError（旧 bug：取消后点击必崩）。
        var stale = document.getElementById('desire-picker-style');
        if (stale) stale.remove();
        teardown();
        window.webkit.messageHandlers.elementPicker.postMessage({cssSelector: sel, xpath: xp});
    }
    function onKey(e) {
        if (e.key === 'Escape') { teardown(); }
    }
    function teardown() {
        document.removeEventListener('mouseover', onOver, true);
        document.removeEventListener('mouseout', onOut, true);
        document.removeEventListener('click', onPick, true);
        document.removeEventListener('keydown', onKey, true);
        var s = document.getElementById('desire-picker-style');
        if (s) s.remove();
        if (hl) hl.classList.remove('desire-picker-highlight');
        hl = null;
        window.__desirePickerTeardown = null;
    }
    window.__desirePickerTeardown = teardown;

    document.addEventListener('mouseover', onOver, true);
    document.addEventListener('mouseout', onOut, true);
    document.addEventListener('click', onPick, true);
    document.addEventListener('keydown', onKey, true);
})();