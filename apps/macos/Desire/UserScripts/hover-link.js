// hover-link.js
// Source: Desire/Features/Browsing/WebView.swift (BrowserState.init, hoverJS)
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false
// Reports hovered anchor hrefs to the `hoverLink` message handler so the
// status bar can display them (empty string on mouseout clears it).
(function() {
    document.addEventListener('mouseover', function(e) {
        var link = e.target.closest('a');
        if (link && link.href) {
            window.webkit.messageHandlers.hoverLink.postMessage(link.href);
        }
    }, true);
    document.addEventListener('mouseout', function(e) {
        var link = e.target.closest('a');
        if (link) {
            window.webkit.messageHandlers.hoverLink.postMessage('');
        }
    }, true);
})();
