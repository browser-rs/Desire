// fullscreen-shim.js — 网页满屏版（2026-09-20 裁决）
// Injected as: WKUserScript @ atDocumentStart (main frame + subframes)
//
// Element fullscreen 在 macOS 26 + SwiftUI 承载下损坏（全屏视口 0×0、
// VisionKit NaN 崩溃,见 WebView.swift 注释）,已禁用。本 shim 让播放器
// 全屏按钮走**纯 CSS 网页满屏**：视频以 CSS 铺满 webview 视口,不触碰
// WebKit 全屏管线、不操作窗口——前几轮的黑屏/自动退屏均来自那两层。
// 配合系统窗口全屏（⌃⌘F）即得完整全屏体验。
(function() {
    if (window.__desireFullscreenShim) return;
    window.__desireFullscreenShim = true;

    var style = document.createElement('style');
    style.textContent =
        '.desire-fs { position: fixed !important; inset: 0 !important;' +
        ' width: 100% !important; height: 100% !important;' +
        ' max-width: none !important; max-height: none !important;' +
        ' min-width: 0 !important; min-height: 0 !important;' +
        ' margin: 0 !important; transform: none !important;' +
        ' border-radius: 0 !important; background: #000 !important; z-index: 2147483647 !important; }' +
        '.desire-fs video { width: 100% !important; height: 100% !important;' +
        ' object-fit: contain !important; }' +
        'body.desire-fs-on { overflow: hidden !important; }';
    (document.head || document.documentElement).appendChild(style);

    // 进入满屏的时间戳:窗口全屏/退出的动画会连发 resize,动画中间态
    // 会被误判为"用户离开了满屏"——进入后 1s 内的 resize 一律忽略。
    var lastEnterAt = 0;

    function enterFS(el) {
        window.__desireFSEl = el;
        el.classList.add('desire-fs');
        document.body.classList.add('desire-fs-on');
        lastEnterAt = Date.now();
        document.dispatchEvent(new Event('fullscreenchange'));
    }

    function exitFS() {
        var el = window.__desireFSEl;
        if (!el) return;
        el.classList.remove('desire-fs');
        document.body.classList.remove('desire-fs-on');
        window.__desireFSEl = null;
        document.dispatchEvent(new Event('fullscreenchange'));
    }

    Element.prototype.requestFullscreen = function() {
        var self = this;
        enterFS(this);
        return Promise.resolve(self);
    };
    Element.prototype.webkitRequestFullscreen = function() {
        enterFS(this);
        document.dispatchEvent(new Event('fullscreenchange'));
    };
    Document.prototype.exitFullscreen = function() {
        exitFS();
        document.dispatchEvent(new Event('fullscreenchange'));
        return Promise.resolve();
    };
    Document.prototype.webkitExitFullscreen = function() {
        exitFS();
        document.dispatchEvent(new Event('fullscreenchange'));
    };

    // Emulate the fullscreen DOM state so player UIs (YouTube checks
    // document.fullscreenElement) engage their fullscreen styling.
    try {
        Object.defineProperty(document, 'fullscreenElement', {
            configurable: true,
            get: function() { return window.__desireFSEl || null; }
        });
        Object.defineProperty(document, 'webkitFullscreenElement', {
            configurable: true,
            get: function() { return window.__desireFSEl || null; }
        });
        Object.defineProperty(document, 'fullscreenEnabled', {
            configurable: true,
            get: function() { return true; }
        });
    } catch (e) {}

    // 窗口被缩到很小 / 退出窗口全屏时释放页面样式。1s 防抖避开
    // 窗口全屏进入动画的 resize 风暴。
    window.addEventListener('resize', function() {
        if (!window.__desireFSEl) return;
        if (Date.now() - lastEnterAt < 1000) return;
        if (window.outerHeight <= window.screen.availHeight * 0.75) {
            exitFS();
        }
    });
})();
