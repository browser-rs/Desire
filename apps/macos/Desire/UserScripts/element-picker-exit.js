// element-picker-exit.js
// Source: Desire/Features/Browsing/WebView.swift (WebView.exitPickerJS)
// Injected as: one-shot evaluateJavaScript (from ContentView when leaving
// element-block or AI element-pick mode without a selection).
// Removes the picker style element and clears any lingering highlight.
(function() {
    var s = document.getElementById('desire-picker-style');
    if (s) s.remove();
    var h = document.querySelector('.desire-picker-highlight');
    if (h) h.classList.remove('desire-picker-highlight');
})();
