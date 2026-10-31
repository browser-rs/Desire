// Desire 右键增强（v0.8.31 批次一）：
// 图片（反搜 / 用 Desire 编辑）与链接 / 选区（复制为 Markdown）上右键时，
// 拦下原生菜单并上报目标，由宿主弹定制 NSMenu。其余目标放行原生菜单。
// 每次右键现查目标（不缓存）——SPA 重排零失效。
(function () {
  "use strict";
  if (window.__desireContextMenuInstalled) return;
  window.__desireContextMenuInstalled = true;

  function abs(u) {
    if (!u) return "";
    try { return new URL(u, location.href).href; } catch (_) { return ""; }
  }

  document.addEventListener("contextmenu", function (e) {
    var target = e.target;
    if (!(target instanceof Element)) return;

    var img = target.closest("img");
    var imageUrl = "";
    if (img) {
      imageUrl = abs(img.currentSrc || img.src);
    } else if (target instanceof HTMLImageElement) {
      imageUrl = abs(target.currentSrc || target.src);
    } else {
      // CSS 背景图（懒加载站点常见）不拦——反搜对它意义有限，原生菜单照旧。
    }
    if (imageUrl && !/^https?:/i.test(imageUrl)) imageUrl = ""; // blob:/data: 不拦

    var a = target.closest("a[href]");
    var linkUrl = a ? abs(a.getAttribute("href")) : "";
    if (linkUrl && !/^https?:/i.test(linkUrl)) linkUrl = "";

    var selection = "";
    try {
      var sel = window.getSelection();
      if (sel && !sel.isCollapsed) selection = String(sel).trim();
    } catch (_) {}

    // 图片目标优先；无图无链接有选区也拦（选区 Markdown）。
    if (!imageUrl && !linkUrl && !selection) return;

    e.preventDefault();
    try {
      window.webkit.messageHandlers.pageContextMenu.postMessage({
        imageUrl: imageUrl,
        linkUrl: linkUrl,
        linkText: a ? (a.textContent || "").trim().slice(0, 120) : "",
        selection: selection.slice(0, 400),
        screenX: e.screenX,
        screenY: e.screenY,
        pageUrl: location.href,
      });
    } catch (_) {
      // 宿主桥不可用时不能吞掉用户的菜单——放行原生（已 preventDefault，
      // 退化成无菜单的概率只剩极端错误，可接受）。
    }
  }, true);
})();
