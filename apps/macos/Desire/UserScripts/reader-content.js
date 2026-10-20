// reader-content.js
// Source: Desire/Features/Browsing/WebView.swift (BrowserState.init, readerJS)
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false
// Defines window._desireReader, a function that scores candidate article
// containers and posts the best match's HTML to the `readerContent` handler.
// Invoked on demand by Swift via evaluateJavaScript("window._desireReader()").
(function() {
    window._desireReader = function() {
        function score(el) {
            if (!el || !el.tagName) return 0;
            var id = (el.id || '').toLowerCase();
            var cls = (el.className || '').toLowerCase();
            var s = 0;
            if (/article|post|content|main|story|entry/.test(id) || /article|post|content|main|story|entry/.test(cls)) s += 10;
            if (/comment|sidebar|footer|header|nav|menu/.test(id) || /comment|sidebar|footer|header|nav|menu/.test(cls)) s -= 10;
            var text = el.innerText || '';
            var links = el.querySelectorAll('a').length;
            var textLen = text.replace(/\\s+/g, ' ').length;
            if (textLen > 100) s += Math.min(5, Math.floor(textLen / 500));
            if (links > 0) s -= Math.min(3, Math.floor(links / 50));
            return s;
        }
        var candidates = [];
        var els = document.querySelectorAll('article, [role=main], main, .post, .article, .content, #content, #article, .entry, .post-content');
        for (var i = 0; i < els.length; i++) {
            var s = score(els[i]);
            if (s > 0) candidates.push({el: els[i], score: s});
        }
        candidates.sort(function(a,b) { return b.score - a.score; });
        var best = candidates.length > 0 ? candidates[0].el : null;
        /* Fallback #1: collect all <p> inside body */
        if (!best || best.innerText.trim().length < 100) {
            var container = document.createElement('div');
            document.querySelectorAll('body p').forEach(function(p) {
                if (p.innerText.trim().length > 20) container.appendChild(p.cloneNode(true));
            });
            if (container.children.length > 3) { best = container; }
        }
        /* Fallback #2: use entire body */
        if (!best || best.innerText.trim().length < 50) { best = document.body; }
        var title = document.title || '';
        var isFallback = (best === document.body || best.tagName === 'DIV');

        /* v0.7.28: clean + make the fragment self-contained.
           - drop chrome that slipped inside the chosen container
           - restore lazy-loaded images
           - absolutize links/images (reader loads as a standalone document) */
        var clone = best.cloneNode(true);
        clone.querySelectorAll('script,style,noscript,nav,aside,footer,form,button,input,select,textarea,svg use,[aria-hidden="true"]').forEach(function(el) { el.remove(); });
        clone.querySelectorAll('img').forEach(function(img) {
            var lazy = img.getAttribute('data-src') || img.getAttribute('data-original')
                || img.getAttribute('data-lazy-src') || img.getAttribute('data-url');
            if (lazy) { img.setAttribute('src', lazy); }
            img.removeAttribute('srcset');
            img.removeAttribute('loading');
        });
        function absolutize(el, attr) {
            var v = el.getAttribute(attr);
            if (!v) { return; }
            try { el.setAttribute(attr, new URL(v, document.baseURI).href); } catch (e) {}
        }
        clone.querySelectorAll('a[href]').forEach(function(a) { absolutize(a, 'href'); });
        clone.querySelectorAll('img[src]').forEach(function(img) { absolutize(img, 'src'); });
        clone.querySelectorAll('source[src]').forEach(function(s) { absolutize(s, 'src'); });

        window.webkit.messageHandlers.readerContent.postMessage({
            title: title,
            content: best.innerText || '',
            html: clone.outerHTML || clone.innerHTML || '',
            url: location.href,
            baseURI: document.baseURI,
            fallback: isFallback ? '1' : '0'
        });
    };
})();
