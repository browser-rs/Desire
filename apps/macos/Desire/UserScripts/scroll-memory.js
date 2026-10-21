// scroll-memory.js (v0.7.29)
// Injected at atDocumentEnd, main frame only. Reports throttled scroll
// positions so the host can restore them after a content-process crash
// (WebKit's interactionState is not available once the process is gone).
(function () {
  if (window.__desireScrollMemoryInstalled) { return; }
  window.__desireScrollMemoryInstalled = true;
  var last = 0, timer = null;

  function post() {
    var y = window.scrollY || 0;
    if (Math.abs(y - last) < 40) { return; }
    last = y;
    try {
      window.webkit.messageHandlers.scrollPosition.postMessage({ y: y, url: location.href });
    } catch (e) {}
  }

  window.addEventListener('scroll', function () {
    if (timer) { return; }
    timer = setTimeout(function () { timer = null; post(); }, 600);
  }, { passive: true });

  window.addEventListener('pagehide', post);
})();
