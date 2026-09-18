// fullscreen-shim.js
// Injected as: WKUserScript @ atDocumentStart (main frame + subframes)
//
// Mainstream video-fullscreen behavior for a WKWebView macOS browser, in
// ONE animation: the page's requestFullscreen/exitFullscreen is rerouted
// to the host app (native window fullscreen toggle) and the requesting
// element is pinned to the viewport with plain CSS. Deliberately NO px
// geometry math here — viewport-relative CSS cannot go stale during the
// native fullscreen animation (px sizing caused black bars), and site
// players (YouTube) apply their own fullscreen styles because
// document.fullscreenElement is emulated.
(function() {
    if (window.__desireFullscreenShim) return;
    window.__desireFullscreenShim = true;

    var style = document.createElement('style');
    style.textContent =
        '.desire-fs { position: fixed !important; inset: 0 !important;' +
        ' width: 100% !important; height: 100% !important;' +
        ' max-width: none !important; max-height: none !important;' +
        ' min-width: 0 !important; min-height: 0 !important;' +
        ' margin: 0 !important; transform: none !important;' +
        ' border-radius: 0 !important; background: #000 !important; }' +
        '.desire-fs video { width: 100% !important; height: 100% !important;' +
        ' object-fit: contain !important; }' +
        'body.desire-fs-on { overflow: hidden !important; }';
    (document.head || document.documentElement).appendChild(style);

    function notify(enter) {
        try {
            window.webkit.messageHandlers.fullscreenRequest.postMessage({ enter: enter });
        } catch (e) {}
    }

    function enterFS(el) {
        window.__desireFSEl = el;
        el.classList.add('desire-fs');
        document.body.classList.add('desire-fs-on');
        notify(true);
        document.dispatchEvent(new Event('fullscreenchange'));
    }

    function exitFS() {
        var el = window.__desireFSEl;
        if (!el) return;
        el.classList.remove('desire-fs');
        document.body.classList.remove('desire-fs-on');
        window.__desireFSEl = null;
        notify(false);
        document.dispatchEvent(new Event('fullscreenchange'));
    }

    Element.prototype.requestFullscreen = function() {
        var self = this;
        enterFS(this);
        return Promise.resolve(self);
    };
    Element.prototype.webkitRequestFullscreen = function() {
        enterFS(this);
        document.dispatchEvent(new Event('fullscreenchange'));
    };
    Document.prototype.exitFullscreen = function() {
        exitFS();
        document.dispatchEvent(new Event('fullscreenchange'));
        return Promise.resolve();
    };
    Document.prototype.webkitExitFullscreen = function() {
        exitFS();
        document.dispatchEvent(new Event('fullscreenchange'));
    };

    // Emulate the fullscreen DOM state so player UIs (YouTube checks
    // document.fullscreenElement) engage their fullscreen styling.
    try {
        Object.defineProperty(document, 'fullscreenElement', {
            configurable: true,
            get: function() { return window.__desireFSEl || null; }
        });
        Object.defineProperty(document, 'webkitFullscreenElement', {
            configurable: true,
            get: function() { return window.__desireFSEl || null; }
        });
        Object.defineProperty(document, 'fullscreenEnabled', {
            configurable: true,
            get: function() { return true; }
        });
    } catch (e) {}

    // The native window left fullscreen at the macOS level (ESC / shortcut)
    // — release the page styles so the video returns to the page layout.
    window.addEventListener('resize', function() {
        if (window.__desireFSEl && window.outerHeight <= window.screen.availHeight * 0.75) {
            exitFS();
        }
    });
})();
