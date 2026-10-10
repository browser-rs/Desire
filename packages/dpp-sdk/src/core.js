/**
 * desire-dpp-sdk — core（宿主环境可注入）
 *
 * Desire Page Protocol (DPP) L3 SDK 的单一逻辑源：不直接触碰 window，
 * 宿主桥经 `env` 注入——build 脚本由它拼出两个产物：
 *   - dist/desire-sdk.js   UMD/IIFE（浏览器 <script> 直接引，挂 window.desire）
 *   - dist/desire-sdk.esm.js  ESM（bundler / `import { createDesireSDK }`）
 *
 * 协议规范：仓库 docs/DPP-PROTOCOL.md
 *
 * env（由包装器提供）：
 *   - postControl(payload): 把 {kind:"reparse"} 送进宿主（Desire 浏览器
 *     经 window.webkit.messageHandlers.desireProtocolControl）
 *   - postEvent(payload): 事件发射通道（desireProtocolEvent）
 *   - global: 顶层对象（UMD = window；ESM 冒烟 = 假 window）
 */
function createDesireSDK(env) {
    var global = env.global;
    var VERSION = "1.0.0";

    var DesireSDK = {
        version: VERSION,
        _protocol: null,
        _debug: false,

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
            global.__desireProtocolExposed = JSON.parse(JSON.stringify(protocol));
            // SPA 路由变化的重新 expose 需要宿主重新解析——宿主只在 didFinish
            // 解析一次，不通知的话新声明永远不会进 pageProtocol 缓存。
            try {
                env.postControl({ kind: "reparse" });
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
                env.postEvent({
                    host: global.location ? global.location.host : "",
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
        }
    };

    return DesireSDK;
}

/** 宿主桥（真实浏览器环境）：WebKit script message handlers。 */
function browserEnv(global) {
    return {
        global: global,
        postControl: function(payload) {
            global.webkit.messageHandlers.desireProtocolControl.postMessage(payload);
        },
        postEvent: function(payload) {
            global.webkit.messageHandlers.desireProtocolEvent.postMessage(payload);
        }
    };
}
