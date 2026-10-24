/* Vim 模式（v0.8.6）：可选键盘增强。
 * j/k 上下滚动、h/l 左右、gg/G 顶/底、x 关标签（→原生）、
 * t 新标签（→原生）、/ 进入查找（→原生）、Esc 退出。
 * 仅在非输入框焦点时生效；capture 阶段先于页面 handler。
 */
(function() {
  'use strict';
  if (window.__desireVimMode) return;
  window.__desireVimMode = true;

  var pendingG = false; // gg/G 双击判定

  function isInputFocused() {
    var el = document.activeElement;
    if (!el) return false;
    var tag = el.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true;
    if (el.isContentEditable) return true;
    return false;
  }

  function scrollBy(dy) {
    window.scrollBy({ top: dy, behavior: 'smooth' });
  }

  document.addEventListener('keydown', function(e) {
    if (isInputFocused()) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    // 让修饰键组合穿透
    var key = e.key;

    if (pendingG) {
      pendingG = false;
      if (key === 'g') { window.scrollTo({ top: 0, behavior: 'smooth' }); e.preventDefault(); return; }
      if (key === 'G') { window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' }); e.preventDefault(); return; }
      return;
    }

    switch (key) {
      case 'j': scrollBy(80); e.preventDefault(); break;
      case 'k': scrollBy(-80); e.preventDefault(); break;
      case 'h': window.scrollBy({ left: -80, behavior: 'smooth' }); e.preventDefault(); break;
      case 'l': window.scrollBy({ left: 80, behavior: 'smooth' }); e.preventDefault(); break;
      case 'g': pendingG = true; e.preventDefault(); break;
      case 'G': window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' }); e.preventDefault(); break;
      case 'x':
        // 关标签：交给原生侧（不能 window.close()）
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vimAction) {
          window.webkit.messageHandlers.vimAction.postMessage({ action: 'closeTab' });
        }
        e.preventDefault();
        break;
      case 't':
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vimAction) {
          window.webkit.messageHandlers.vimAction.postMessage({ action: 'newTab' });
        }
        e.preventDefault();
        break;
      case '/':
        // 进入查找：交给原生侧
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vimAction) {
          window.webkit.messageHandlers.vimAction.postMessage({ action: 'find' });
        }
        e.preventDefault();
        break;
    }
  }, true); // capture：先于页面 handler
})();
