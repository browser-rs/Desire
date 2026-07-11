// element-picker.js
// Source: Desire/Features/Browsing/WebView.swift (WebView.pickerJS)
// Injected as: one-shot evaluateJavaScript (from ContentView when entering
// element-block or AI element-pick mode).
// Injects a highlight style, builds a stable CSS selector + XPath for the
// clicked element, and posts both to the `elementPicker` handler.
(function() {
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
                var idx = ch.indexOf(el) + 1;
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
        document.head.removeChild(style);
        document.removeEventListener('mouseover', onOver, true);
        document.removeEventListener('mouseout', onOut, true);
        document.removeEventListener('click', onPick, true);
        window.webkit.messageHandlers.elementPicker.postMessage({cssSelector: sel, xpath: xp});
    }
    document.addEventListener('mouseover', onOver, true);
    document.addEventListener('mouseout', onOut, true);
    document.addEventListener('click', onPick, true);
})();
