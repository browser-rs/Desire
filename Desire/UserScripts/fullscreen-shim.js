// fullscreen-shim.js
// Injected as: WKUserScript @ atDocumentStart (main frame + subframes)
//
// WebKit's element fullscreen on macOS fullscreens the WEBVIEW in its own
// Space while the host window stays behind — users see "two windows", and
// WebKit's internal confirm dialog adds a third surprise. There is no
// public WKUIDelegate hook to take over the prompt.
//
// This shim reroutes the Fullscreen API to the host app instead: the
// native side fullscreens the actual WINDOW (macOS convention) and we
// dispatch fullscreenchange so site UI (YouTube's player styling) follows.
(function() {
    if (window.__desireFullscreenShim) return;
    window.__desireFullscreenShim = true;

    function notify(enter) {
        try {
            window.webkit.messageHandlers.fullscreenRequest.postMessage({ enter: enter });
        } catch (e) {}
        document.dispatchEvent(new Event('fullscreenchange'));
    }

    Element.prototype.requestFullscreen = function(options) {
        notify(true);
        return Promise.resolve();
    };
    // Legacy webkit prefix (Safari-era players).
    Element.prototype.webkitRequestFullscreen = function() {
        notify(true);
        return Promise.resolve();
    };
    Document.prototype.exitFullscreen = function() {
        notify(false);
        return Promise.resolve();
    };
    Document.prototype.webkitExitFullscreen = function() {
        notify(false);
    };
})();
