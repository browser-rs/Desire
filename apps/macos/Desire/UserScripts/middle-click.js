// middle-click.js
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false
// WKWebView has no built-in middle-click behavior (Safari implements its
// own). This reports middle-clicked (auxiliary button, button === 1) anchor
// hrefs to the `middleClickLink` message handler so the host can open them
// in a new tab. Absolute resolution against the page URL happens here — the
// handler only ever sees an absolute http(s) URL.
(function() {
    if (window.__desireMiddleClickInstalled) return;
    window.__desireMiddleClickInstalled = true;
    document.addEventListener('auxclick', function(e) {
        if (e.button !== 1) return;
        var link = e.target.closest && e.target.closest('a[href]');
        if (!link) return;
        var href = link.getAttribute('href') || '';
        // Same-page anchors are not navigations.
        if (!href || href.charAt(0) === '#') return;
        var url;
        try {
            url = new URL(href, location.href);
        } catch (err) {
            return;
        }
        if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
        e.preventDefault();
        e.stopPropagation();
        window.webkit.messageHandlers.middleClickLink.postMessage(url.href);
    }, true);
})();
