// media-sniffer.js
// Injected at documentStart (all frames). Watches every fetch/XHR the page
// makes and reports video/audio/stream resources to the app, so the agent
// can extract REAL media addresses even when the player uses blob: URLs —
// the m3u8/mp4/segment requests that feed the blob are visible here, while
// the blob: URL itself is useless outside the page.
//
// Reports go to the `mediaFound` script-message handler (BrowserState).
(function () {
    if (window.__desireMediaSniffer) return;
    window.__desireMediaSniffer = true;

    var MEDIA_EXT = /\.(mp4|webm|mkv|mov|m4v|flv|avi|ts|m3u8|mpd|mp3|m4a|aac|flac|wav|ogg|opus)(\?|#|$)/i;
    var STREAM_MIME = /(mpegurl|dash\+xml)/i;

    function classify(url, mime) {
        mime = (mime || "").toLowerCase();
        if (STREAM_MIME.test(mime) || /\.m3u8(\?|#|$)|\.mpd(\?|#|$)/i.test(url)) return "stream";
        if (/^video\//.test(mime) || /\.(mp4|webm|mkv|mov|m4v|flv|avi|ts)(\?|#|$)/i.test(url)) return "video";
        if (/^audio\//.test(mime) || /\.(mp3|m4a|aac|flac|wav|ogg|opus)(\?|#|$)/i.test(url)) return "audio";
        return null;
    }

    var reported = {};
    function report(url, mime, size, source) {
        if (!url || typeof url !== "string") return;
        if (url.indexOf("data:") === 0 || url.indexOf("blob:") === 0) return;
        var k = classify(url, mime);
        if (!k) return;
        if (reported[url]) {
            // Seen before — refresh size only if we learned it later.
            return;
        }
        reported[url] = true;
        try {
            window.webkit.messageHandlers.mediaFound.postMessage({
                url: url.substring(0, 4000),
                mime: (mime || "").substring(0, 100),
                kind: k,
                size: size || 0,
                source: source || "network"
            });
        } catch (err) {}
    }

    // --- fetch hook ---
    var origFetch = window.fetch;
    if (origFetch) {
        window.fetch = function (input, init) {
            var url = "";
            try {
                url = (input && input.url) || String(input || "");
            } catch (e) {}
            var promise = origFetch.apply(this, arguments);
            promise.then(function (resp) {
                var mime = "", size = 0;
                try { mime = resp.headers.get("content-type") || ""; } catch (e1) {}
                try { size = parseInt(resp.headers.get("content-length") || "0", 10) || 0; } catch (e2) {}
                report((resp && resp.url) || url, mime, size, "fetch");
            }).catch(function () {});
            return promise;
        };
    }

    // --- XHR hook ---
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
        try { this.__desireUrl = String(url || ""); } catch (e) {}
        return origOpen.apply(this, arguments);
    };
    var origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        xhr.addEventListener("load", function () {
            var url = xhr.__desireUrl || (xhr.responseURL || "");
            var mime = "", size = 0;
            try { mime = xhr.getResponseHeader("Content-Type") || ""; } catch (e1) {}
            try { size = parseInt(xhr.getResponseHeader("Content-Length") || "0", 10) || 0; } catch (e2) {}
            if (!mime) { try { mime = xhr.contentType || ""; } catch (e3) {} }
            report(url, mime, size, "xhr");
        });
        return origSend.apply(this, arguments);
    };
})();
