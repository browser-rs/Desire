// page-perf.js
// Source: Desire/Features/Tabs/TabAudioControl.swift 同族的性能观测脚本（0.6.4）
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false, page world
// 大页面守护 + 性能快照的数据面：
//  - 每 5s 上报 DOM 节点数（主框架；大页面守护的代理指标——WebKit 无公开
//    per-tab 内存 API，见 docs/ROADMAP.md 0.6.4 诚实口径）
//  - PerformanceObserver 统计 long task（>50ms，buffered: true 兜住脚本
//    注入前发生的卡顿），随 domStats 一并上报
(function() {
    "use strict";
    if (window.__desirePagePerf) return;
    window.__desirePagePerf = true;

    var longTasks = 0;
    var longTaskMs = 0;
    try {
        var obs = new PerformanceObserver(function (list) {
            list.getEntries().forEach(function (e) {
                longTasks += 1;
                longTaskMs += e.duration;
            });
        });
        obs.observe({ entryTypes: ["longtask"], buffered: true });
    } catch (e) { /* 引擎不支持 longtask 时静默 */ }

    function report() {
        try {
            var nodes = document.getElementsByTagName("*").length;
            window.webkit.messageHandlers.pagePerf.postMessage({
                domNodes: nodes,
                longTasks: longTasks,
                longTaskMs: Math.round(longTaskMs)
            });
        } catch (e) { /* 页面世界被站点污染时静默 */ }
    }

    setInterval(report, 5000);
    setTimeout(report, 1200);
})();
