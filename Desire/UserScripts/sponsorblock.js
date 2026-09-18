// sponsorblock.js
// Injected at didFinish (youtube.com, when the toggle is on) — the same
// pattern as dark-mode-inject.
//
// Skips in-video sponsor segments on YouTube via the SponsorBlock community
// database (https://sponsor.ajay.app, k-anonymity-free simple GET). v1
// skips sponsor / selfpromo / interaction by default.
(function() {
    if (window.__desireSponsorBlock) return;
    window.__desireSponsorBlock = true;

    if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;

    var API = 'https://sponsor.ajay.app/api/skipSegments?videoID=';
    // sponsor=ad readout, selfpromo=own promotion, interaction=like/subscribe reminders
    var CATEGORIES = ['sponsor', 'selfpromo', 'interaction'];
    var segments = [];
    var currentVideoID = null;

    function videoID() {
        var m = location.search.match(/[?&]v=([\w-]{11})/);
        if (m) return m[1];
        var shorts = location.pathname.match(/\/(?:shorts|live)\/([\w-]{11})/);
        return shorts ? shorts[1] : null;
    }

    function fetchSegments(id) {
        var url = API + id + '&categories=' + encodeURIComponent(JSON.stringify(CATEGORIES));
        fetch(url)
            .then(function(r) { return r.ok ? r.json() : []; })
            .then(function(list) {
                segments = (list || []).map(function(x) { return x.segment; }).filter(Boolean);
                attach();
            })
            .catch(function() {});
    }

    function videoEl() {
        return document.querySelector('video.html5-main-video') || document.querySelector('video');
    }

    function attach() {
        var v = videoEl();
        if (!v || v.__desireSBHooked) return;
        v.__desireSBHooked = true;
        v.addEventListener('timeupdate', function() {
            if (!segments.length) return;
            var t = v.currentTime;
            for (var i = 0; i < segments.length; i++) {
                var s = segments[i];
                if (t >= s[0] && t < s[1] - 0.15) {
                    v.currentTime = s[1];
                    toast('已跳过赞助片段');
                    break;
                }
            }
        });
    }

    function toast(text) {
        var host = document.querySelector('#movie_player') || document.body;
        if (!host) return;
        var el = document.createElement('div');
        el.textContent = text;
        el.style.cssText = 'position:fixed;bottom:60px;left:50%;transform:translateX(-50%);' +
            'background:rgba(0,0,0,.8);color:#fff;padding:6px 14px;border-radius:18px;' +
            'z-index:2147483647;font-size:13px;pointer-events:none;transition:opacity .5s';
        host.appendChild(el);
        setTimeout(function() {
            el.style.opacity = '0';
            setTimeout(function() { el.remove(); }, 600);
        }, 1500);
    }

    function init() {
        var id = videoID();
        if (id && id !== currentVideoID) {
            currentVideoID = id;
            segments = [];
            fetchSegments(id);
        }
        attach();
    }

    // YouTube is a SPA: watch-page transitions fire yt-navigate-finish.
    window.addEventListener('yt-navigate-finish', init);
    // Fallback for player element creation / non-event paths.
    setInterval(init, 1500);
})();
