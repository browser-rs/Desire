// selection-ai.js
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: true
//
// Watches text selections and reports them to Swift so the AI selection bar
// can appear next to the highlighted text. Posts {text:''} when the
// selection collapses (click-away) so the bar dismisses itself.
(function() {
    var debounce = null;
    document.addEventListener('selectionchange', function() {
        if (debounce) clearTimeout(debounce);
        debounce = setTimeout(function() {
            var sel = window.getSelection();
            var text = sel ? (sel.toString() || '').trim() : '';
            if (!sel || !sel.rangeCount || text.length < 2) {
                window.webkit.messageHandlers.selectionAI.postMessage({ text: '' });
                return;
            }
            var rect = sel.getRangeAt(0).getBoundingClientRect();
            if (!rect || (rect.width < 2 && rect.height < 2)) { return; }
            window.webkit.messageHandlers.selectionAI.postMessage({
                text: text.substring(0, 4000),
                x: rect.left,
                y: rect.top,
                h: rect.height
            });
        }, 250);
    });
})();
