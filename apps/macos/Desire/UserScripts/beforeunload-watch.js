// beforeunload-watch.js
// Injected as: WKUserScript @ atDocumentStart **and** atDocumentEnd,
// forMainFrameOnly: true, page world（两遍注入，见下方"注入两遍"注释）
// （v0.8.84 批 2 第 3 件：导航守卫零 JS 化的数据面）
//
// 目的：主框架导航的 beforeunload 守卫（表单数据保护）原本**每次导航**
// 都跑一次合成探针的 JS 往返——对没有监听器的页面（绝大多数）是纯浪费。
// 本脚本在 documentStart 装两道**不可探测的拦截**，页面注册
// beforeunload 监听器的那一瞬间发一条消息置原生标志：
//   1. `window.onbeforeunload` 用**自有 accessor 影子**接管（WebKit 里
//      原生 accessor 是 window 的自有属性；get/set 透传原生实现，
//      `window.onbeforeunload = fn` 会经过这里）；
//   2. `window.addEventListener` 用 **Proxy 包原生函数**——Function.prototype
//      .toString 对 Proxy 按规范返回 target 的 native 字符串，站点探测
//      `toString().includes('[native code]')` 依旧通过（本项目的合成探针
//      本来就会临时改写 onbeforeunload，探测面没有变大）。
// 只置一次性标志、从不读回：命中即上报，移除监听器不清零（多探一次
// 只是回到既有行为，无损）。宿主在新文档 didStart 时复位。
(function() {
    "use strict";
    var reported = false;
    function report() {
        if (reported) return;
        reported = true;
        try {
            window.webkit.messageHandlers.beforeUnloadWatch.postMessage(
                { registered: true });
        } catch (e) { /* 宿主未注册时静默（创建期 handler 已兜住） */ }
    }
    // 本脚本注入**两遍**（documentStart + documentEnd，见 UserScriptLoader）：
    // start 装拦截钩子；end 兜底检查 `<body onbeforeunload>`——解析器把
    // 内容属性转成 window 处理器时**不经过 JS 可见的 setter**，赋值侧
    // 拦截抓不到，只能在解析完成后读一次原生值。report 幂等，重复无害。
    if (!window.__desireBeforeUnloadWatch) {
        window.__desireBeforeUnloadWatch = true;
    }
    try { if (window.onbeforeunload) { report(); } } catch (e) {}


    // 1) IDL 属性影子：onbeforeunload（Window 事件处理器）。
    //    WebKit 实测：原生 accessor 是 **window 的自有属性**（Window.prototype
    //    上没有）——所以取 window 自己的描述符重定义，get/set 透传原生实现。
    //    <body onbeforeunload> 的解析赋值与 `window.onbeforeunload = fn`
    //    都会经过这个 setter。
    try {
        var desc = Object.getOwnPropertyDescriptor(window, "onbeforeunload");
        if (desc && desc.get && desc.set && desc.configurable) {
            Object.defineProperty(window, "onbeforeunload", {
                get: function () { return desc.get.call(this); },
                set: function (v) {
                    if (v !== null && v !== undefined) { report(); }
                    return desc.set.call(this, v);
                },
                configurable: true,
                enumerable: true
            });
        }
    } catch (e) { /* 引擎差异时静默——退化为既有探针路径 */ }

    // 2) addEventListener Proxy：命中 beforeunload 注册即上报。
    try {
        var nativeAdd = window.addEventListener;
        var wrapped = new Proxy(nativeAdd, {
            apply: function (target, thisArg, args) {
                try {
                    if (thisArg === window &&
                        (args[0] === "beforeunload" || args[0] === "beforeunload ")) {
                        report();
                    }
                } catch (e) { /* 参数畸形时照常透传 */ }
                return Reflect.apply(target, thisArg, args);
            }
        });
        Object.defineProperty(window, "addEventListener", {
            value: wrapped,
            writable: true,
            configurable: true,
            enumerable: true
        });
    } catch (e) { /* 同上，静默退化 */ }
})();
