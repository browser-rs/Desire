// workflow-recorder.js (v0.7.29)
// Injected at atDocumentStart, main frame only. Dormant until the host flips
// window.__desireWorkflowRecording (the host re-enables it on every commit
// while a recording session is active).
//
// Records clicks, input/select changes and SPA URL changes. Values of
// sensitive fields are sent to the host (in-process only) and the host
// clears them before persisting — this script never decides policy.
(function () {
  if (window.__desireWorkflowRecorderInstalled) { return; }
  window.__desireWorkflowRecorderInstalled = true;

  var lastURL = location.href;

  function post(payload) {
    try { window.webkit.messageHandlers.workflowEvent.postMessage(payload); } catch (e) {}
  }
  function active() { return window.__desireWorkflowRecording === true; }

  function cssEscape(value) {
    if (window.CSS && CSS.escape) { return CSS.escape(String(value)); }
    return String(value).replace(/(["\\])/g, '\\$1');
  }

  function selectorCandidates(el) {
    var out = [];
    if (!el || el.nodeType !== 1) { return out; }
    var testid = el.getAttribute('data-testid') || el.getAttribute('data-test') || el.getAttribute('data-cy');
    if (testid) { out.push('[data-testid="' + cssEscape(testid) + '"]'); }
    if (el.id) { out.push('#' + cssEscape(el.id)); }
    var name = el.getAttribute('name');
    if (name) { out.push(el.tagName.toLowerCase() + '[name="' + cssEscape(name) + '"]'); }
    var aria = el.getAttribute('aria-label');
    if (aria) { out.push('[aria-label="' + cssEscape(aria) + '"]'); }
    var text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
    var isButtonish = el.tagName === 'BUTTON' || el.tagName === 'A'
        || (el.getAttribute('role') || '').toLowerCase() === 'button';
    if (text && isButtonish) { out.push('text:' + text); }
    // nth-child path fallback (last resort; page redesigns break it, which is
    // why every step carries the candidates above).
    var path = [];
    var node = el;
    while (node && node.nodeType === 1 && path.length < 8) {
      var parent = node.parentElement;
      if (!parent) { break; }
      var index = Array.prototype.indexOf.call(parent.children, node) + 1;
      path.unshift(node.tagName.toLowerCase() + ':nth-child(' + index + ')');
      node = parent;
    }
    if (path.length) { out.push(path.join(' > ')); }
    return out;
  }

  function fieldMeta(el) {
    return {
      type: el.getAttribute('type'),
      autocomplete: el.getAttribute('autocomplete'),
      name: el.getAttribute('name'),
      id: el.id || null,
      placeholder: el.getAttribute('placeholder'),
    };
  }

  document.addEventListener('click', function (event) {
    if (!active()) { return; }
    var target = event.target;
    if (!target || !target.closest) { return; }
    var el = target.closest('a,button,[role=button],input,select,textarea,label');
    if (!el) { return; }
    // Values of form controls are captured by the change handler.
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') { return; }
    var note = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
    post({ type: 'click', selectors: selectorCandidates(el), note: note });
  }, true);

  document.addEventListener('change', function (event) {
    if (!active()) { return; }
    var el = event.target;
    if (!el || !/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) { return; }
    var kind = el.tagName === 'SELECT' ? 'select' : 'input';
    post({
      type: kind,
      selectors: selectorCandidates(el),
      value: el.value || '',
      field: fieldMeta(el),
      note: (el.getAttribute('name') || el.id || el.tagName).slice(0, 80),
    });
  }, true);

  function checkURL() {
    if (!active()) { return; }
    if (location.href !== lastURL) {
      lastURL = location.href;
      post({ type: 'navigate', url: location.href });
    }
  }

  ['pushState', 'replaceState'].forEach(function (name) {
    var original = history[name];
    if (!original) { return; }
    history[name] = function () {
      var result = original.apply(this, arguments);
      setTimeout(checkURL, 0);
      return result;
    };
  });
  window.addEventListener('popstate', checkURL);
  setInterval(checkURL, 1000);
})();
