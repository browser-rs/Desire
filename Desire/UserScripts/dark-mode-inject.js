// dark-mode-inject.js
// Source: Desire/Features/Browsing/WebView.swift (Coordinator.didFinish, dark-mode blob)
// Injected as: one-shot evaluateJavaScript (after page load, only when the
// site's per-site dark-mode toggle is on).
// Applies an invert/hue-rotate filter to the document and re-inverts media
// so images/video render correctly. Idempotent (guarded by element id).
(function() {
    if (!document.getElementById('desire-dark-mode')) {
        var css = 'html{filter:invert(0.9)hue-rotate(180deg)}img,video,canvas,svg,[style*="background-image"]{filter:invert(1)hue-rotate(180deg)}';
        var s = document.createElement('style');
        s.id = 'desire-dark-mode';
        s.textContent = css;
        document.head.appendChild(s);
    }
})();
