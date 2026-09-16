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
        if (STREAM_MIME.test(mime) || /m3u8|\.mpd/i.test(url)) return "stream";
        if (/^video\//.test(mime) || /\.(mp4|webm|mkv|mov|m4v|flv|avi|ts)(\?|#|$)/i.test(url)) return "video";
        if (/^audio\//.test(mime) || /\.(mp3|m4a|aac|flac|wav|ogg|opus)(\?|#|$)/i.test(url)) return "audio";
        return null;
    }

    var reported = {};
    window.__desireNetLog = window.__desireNetLog || [];
    function logRequest(url, source) {
        if (!url || typeof url !== "string") return;
        if (url.indexOf("data:") === 0) return;
        try {
            window.__desireNetLog.push({ url: url.substring(0, 500), via: source });
            if (window.__desireNetLog.length > 200) window.__desireNetLog.shift();
        } catch (e) {}
    }
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
            logRequest(url, "fetch");
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
        try { this.__desireUrl = String(url || ""); logRequest(String(url || ""), "xhr"); } catch (e) {}
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

    // --- Resource Timing: catches loads that never pass through page JS ---
    // Native <video src="…m3u8"> playback is loaded by WebKit itself; the
    // request never sees fetch/XHR hooks but DOES land in the resource
    // timeline. buffered replays everything loaded before this script.
    try {
        var po = new PerformanceObserver(function (list) {
            var entries = list.getEntries() || [];
            for (var i = 0; i < entries.length; i++) {
                var e = entries[i];
                report(e.name, "", Math.round(e.transferSize || 0), "rt:" + (e.initiatorType || "resource"));
            }
        });
        po.observe({ entryTypes: ["resource"], buffered: true });
    } catch (poErr) {}

    // --- HTMLMediaElement src hooks: catch direct m3u8 assignments even if
    // the player later replaces them with a blob: URL (Safari-detection
    // pattern: try native HLS first, fall back to MSE). ---
    try {
        var mediaProto = HTMLMediaElement.prototype;
        var srcDesc = Object.getOwnPropertyDescriptor(mediaProto, "src");
        if (srcDesc && srcDesc.set) {
            Object.defineProperty(mediaProto, "src", {
                get: srcDesc.get,
                set: function (v) {
                    try { report(String(v || ""), "", 0, "src-attr"); } catch (e) {}
                    srcDesc.set.call(this, v);
                },
                configurable: true
            });
        }
        var origSetAttr = mediaProto.setAttribute;
        mediaProto.setAttribute = function (name, value) {
            try {
                if (String(name).toLowerCase() === "src") report(String(value || ""), "", 0, "src-attr");
            } catch (e) {}
            return origSetAttr.call(this, name, value);
        };
    } catch (hookErr) {}
})();
