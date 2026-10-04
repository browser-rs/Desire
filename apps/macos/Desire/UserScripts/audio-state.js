// audio-state.js
// Source: Desire/Features/Browsing/WebView.swift (BrowserState.init, audioJS)
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false
// Listens for audio/video play/pause/volumechange and reports playback
// state to Swift via the `audioState` message handler.
(function() {
    function checkAudio() {
    var playing = false;
    document.querySelectorAll('audio, video').forEach(function(el) {
        if (!el.paused && el.volume > 0) {
            playing = true;
        }
    });
    window.webkit.messageHandlers.audioState.postMessage(playing);
}
document.addEventListener('play', checkAudio, true);
document.addEventListener('pause', checkAudio, true);
document.addEventListener('volumechange', checkAudio, true);
new MutationObserver(function() {
    if (document.querySelectorAll('audio, video').length) checkAudio();
}).observe(document.body, { childList: true, subtree: true });
setTimeout(checkAudio, 500);
})();
