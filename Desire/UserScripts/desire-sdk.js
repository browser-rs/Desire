/**
 * desire-sdk.js — Desire Page Protocol L3 SDK (v1)
 * DPP for AI agents — 网页的能力声明协议（与 llms.txt 互补）
 * SDK: https://desire.mankong.icu/desire-sdk.js · 规范: docs/DPP-PROTOCOL.md
 *
 * 新开发的网站用这个 SDK 声明 DPP 协议——比手写 JSON 声明块更友好：
 * - 类型安全的 API（视图/信号/动作/事件）
 * - SPA 路由变化时自动重新声明
 * - 事件发射 API（比 MutationObserver 更精确）
 * - dev 模式 schema 校验（console.warn 提示）
 *
 * 用法：
 * <script src="desire-sdk.js"></script>
 * <script>
 *   desire.expose({
 *     page: { type: "catalog" },
 *     content: { main: ".product-grid" },
 *     views: { products: { item: ".card", fields: { title: "h3", price: ".price" } } },
 *     signals: { ready: "[data-app-ready]" },
 *     actions: [ { name: "add-to-cart", run: [{ click: ".add-btn" }], effects: "persist" } ]
 *   });
 * </script>
 *
 * 事件发射（比 DOM 监听更精确，DPP events 的替代方案）：
 *   desire.emit("new-message", { conversationId: "…", text: "…" });
 *
 * 校验（开发时检查协议声明是否完整）：
 *   desire.validate();  // console.log 结果
 */
(function() {
    "use strict";

    var DesireSDK = {
        version: "1.0",
        _protocol: null,
        _eventListener: null,

        /**
         * 声明 DPP 协议。重复调用 = 更新（如 SPA 路由变化）。
         * @param {Object} protocol - DPP 协议声明（同 <script> 声明块格式）
         */
        expose: function(protocol) {
            if (!protocol || typeof protocol !== "object") {
                console.warn("[desire-sdk] expose() requires a protocol object");
                return;
            }
            this._protocol = protocol;
            // 序列化并挂到 window，宿主解析器读取 window.__desireProtocolExposed
            window.__desireProtocolExposed = JSON.parse(JSON.stringify(protocol));
            // SPA 路由变化的重新 expose 需要宿主重新解析——宿主只在 didFinish
            // 解析一次，不通知的话新声明永远不会进 pageProtocol 缓存。
            try {
                window.webkit.messageHandlers.desireProtocolControl.postMessage({ kind: "reparse" });
            } catch (e) {}
            if (this._debug) {
                console.log("[desire-sdk] protocol exposed:", Object.keys(protocol));
            }
        },

        /**
         * 发射自定义事件（绕过 MutationObserver，比 DPP events 声明更精确）。
         * @param {string} eventName - 事件名（对应协议 events 声明）
         * @param {Object} [detail] - 事件详情
         */
        emit: function(eventName, detail) {
            try {
                window.webkit.messageHandlers.desireProtocolEvent.postMessage({
                    host: location.host,
                    eventName: eventName,
                    detail: detail || {}
                });
            } catch (e) {
                console.warn("[desire-sdk] emit failed:", e.message);
            }
        },

        /**
         * 校验当前页面的 DPP 协议声明（开发时调试用）。
         * @returns {Object} { valid: bool, warnings: [], protocol: {} }
         */
        validate: function() {
            var p = this._protocol;
            if (!p) return { valid: false, reason: "no protocol exposed" };
            var warnings = [];
            if (!p.signals || !p.signals.ready) {
                warnings.push("missing signals.ready — agent won't know when the page is loaded");
            }
            if (!p.views || Object.keys(p.views).length === 0) {
                warnings.push("no views declared — agent can't extract structured data");
            }
            if (p.actions) {
                for (var i = 0; i < p.actions.length; i++) {
                    var a = p.actions[i];
                    if (!a.name) warnings.push("action[" + i + "] missing name");
                    if (!a.run) warnings.push("action '" + a.name + "' missing run steps");
                }
            }
            // Profile 契约检查（规范 §5）：声明 profile = 承诺必选原语存在
            var PROFILE_REQUIRED = {
                chat:      { views: ["conversations", "activeThread"], actions: ["send-message"], events: ["new-message"] },
                catalog:   { views: ["items"], actions: ["search"] },
                forms:     { views: ["formFields"], actions: ["submit"] },
                checkout:  { views: ["cart", "orderSummary"], actions: ["place-order"] },
                monitor:   {},
                workbench: { views: ["records"] }
            };
            if (p.profile) {
                var need = PROFILE_REQUIRED[p.profile];
                if (!need) {
                    warnings.push("unknown profile '" + p.profile + "' — no standard contract to follow");
                } else {
                    var viewKeys = Object.keys(p.views || {});
                    var actionNames = (p.actions || []).map(function(x) { return x.name; });
                    var eventKeys = Object.keys(p.events || {});
                    (need.views || []).forEach(function(v) {
                        if (viewKeys.indexOf(v) === -1) warnings.push("profile '" + p.profile + "' requires view '" + v + "'");
                    });
                    (need.actions || []).forEach(function(an) {
                        if (actionNames.indexOf(an) === -1) warnings.push("profile '" + p.profile + "' requires action '" + an + "'");
                    });
                    (need.events || []).forEach(function(ev) {
                        if (eventKeys.indexOf(ev) === -1) warnings.push("profile '" + p.profile + "' requires event '" + ev + "'");
                    });
                }
            }
            return { valid: true, warnings: warnings, views: Object.keys(p.views || {}) };
        },

        /** 开启 dev 调试日志。 */
        debug: function(on) {
            this._debug = on !== false;
        },
        _debug: false
    };

    // 挂载到 window（宿主解析器读取 window.__desireProtocolExposed）
    window.desire = DesireSDK;
})();
