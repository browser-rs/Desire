// webext-api.js — WebExtension API runtime (0.2.13).
// Injected as a WKUserScript in the ISOLATED `desireExtensions` content
// world (see WebView.extensionWorld): page JS cannot see or spoof
// `browser.*` here; plugin code evaluated by PluginStore shares this
// world. The DOM is shared, so plugins still read/manipulate the page.
//
// Surface (v1): storage.local (Promise), tabs.query/create/remove,
// tabs.onCreated/onRemoved/onActivated events, notifications.create,
// runtime.id/getManifest. `chrome.*` is aliased to the same namespaces.
(function() {
    if (window.__desireExt) return;
    var seq = 0, pending = {};
    var listeners = {};
    // 消息传递的回包路由：宿主不用 rpc 的自增 id 回包（它走自己的
    // replyId），这里按路由 id 找回同一个 pending 条目，让原 Promise 落定。
    var routingPending = {};

    function rpc(ns, fn, args) {
        return new Promise(function(resolve, reject) {
            var id = ++seq;
            var entry = { resolve: resolve, reject: reject, id: id };
            pending[id] = entry;
            var callArgs = args || [];
            // 消息传递类调用生成路由 id 一起上送（宿主原样回传 → _resolveReply）。
            var routed = (ns === "runtime" && (fn === "sendMessageToBackground" ||
                                               fn === "sendMessageToTab"));
            if (routed) {
                var rid = "rp-" + Date.now().toString(36) + "-" + id;
                routingPending[rid] = entry;
                callArgs = callArgs.concat([rid]);
            }
            window.webkit.messageHandlers.desireExt.postMessage({
                id: id, ns: ns, fn: fn, args: callArgs,
                // 插件身份（宿主在跑每个插件前设 window.__desireExtID）：
                // 宿主按它选 storage 命名空间。取调用时刻的值——延迟回调
                // （Promise/timer）里发出也必须归到发起它的插件。
                ext: window.__desireExtID || null
            });
        });
    }

    window.__desireExt = {
        // Swift replies here: payload is an embedded JSON literal.
        _resolve: function(id, ok, payload) {
            var p = pending[id];
            if (!p) return;
            delete pending[id];
            if (ok) p.resolve(payload); else p.reject(new Error(String(payload)));
        },
        // 消息传递的回包（宿主持 Swift 侧 replyId 呼入）。noListener 语义
        // 对齐 Chrome：promise reject "Receiving end does not exist."
        _resolveReply: function(rid, ok, payload, noListener) {
            var p = routingPending[rid];
            if (!p) return;
            delete routingPending[rid];
            delete pending[p.id];
            if (ok) p.resolve(payload);
            else p.reject(new Error(noListener
                ? "Could not establish connection. Receiving end does not exist."
                : String(payload)));
        },
        // Swift fans tab events out to registered listeners.
        _fire: function(event, payload) {
            (listeners[event] || []).forEach(function(cb) {
                try {
                    // Chrome 事件签名多参（如 tabs.onUpdated = (tabId, changeInfo,
                    // tab)）：宿主送数组时按位展开，对象/标量仍单参。
                    if (Array.isArray(payload)) cb.apply(null, payload);
                    else cb(payload);
                } catch (e) { /* listener error is its own */ }
            });
        }
    };

    function eventAPI(name) {
        return {
            addListener: function(cb) {
                (listeners[name] = listeners[name] || []).push(cb);
                // Tell the host so fire() only evaluates into interested tabs.
                window.webkit.messageHandlers.desireExt.postMessage({
                    ns: "events", fn: "addListener", args: [name]
                });
            },
            removeListener: function(cb) {
                var l = listeners[name] || [];
                var i = l.indexOf(cb);
                if (i >= 0) l.splice(i, 1);
            },
            hasListener: function(cb) { return (listeners[name] || []).indexOf(cb) >= 0; },
            hasListeners: function() { return (listeners[name] || []).length > 0; }
        };
    }

    var storage = {
        local: {
            get: function(keys) { return rpc("storage", "get", [keys === undefined ? null : keys]); },
            set: function(items) { return rpc("storage", "set", [items || {}]); },
            remove: function(keys) {
                return rpc("storage", "remove", [Array.isArray(keys) ? keys : (keys == null ? [] : [keys])]);
            },
            clear: function() { return rpc("storage", "clear", []); }
        },
        // onChanged(changes, areaName)——宿主在本插件 background 页派发。
        onChanged: eventAPI("storage.onChanged"),
        // sync：Desire 暂无跨设备插件数据通道——别名到 local（Firefox 早期
        // 同款降级；保证依赖 storage.sync 的扩展能跑，语义略降级为本地）。
        sync: null
    };
    storage.sync = storage.local;
    var tabs = {
        query: function() { return rpc("tabs", "query", []); },
        create: function(props) { return rpc("tabs", "create", [props || {}]); },
        remove: function(ids) { return rpc("tabs", "remove", [ids]); },
        get: function(tabId) { return rpc("tabs", "get", [String(tabId)]); },
        update: function(tabId, props) { return rpc("tabs", "update", [String(tabId), props || {}]); },
        reload: function(tabId) { return rpc("tabs", "reload", [tabId === undefined ? null : String(tabId)]); },
        onCreated: eventAPI("tabs.onCreated"),
        onRemoved: eventAPI("tabs.onRemoved"),
        onActivated: eventAPI("tabs.onActivated"),
        // (tabId, changeInfo, tab)——宿主送数组，_fire 按位展开。
        onUpdated: eventAPI("tabs.onUpdated"),
        // background/popup → 页面：宿主经 _tabsMessage 投递进本页。
        // 宿主侧 case 名是 ("runtime","sendMessageToTab")（背景页同一份 rpc）。
        sendMessage: function(tabId, msg) {
            return rpc("runtime", "sendMessageToTab", [tabId, msg === undefined ? null : msg]);
        },
        // 背景发起的长连接（对端 = 该 tab 的内容脚本，runtime.onConnect 收）。
        connect: function(tabId, info) {
            var portId = "port-" + Date.now().toString(36) + "-" + (++seq);
            window.webkit.messageHandlers.desireExt.postMessage({
                ns: "tabs", fn: "connect", args: [String(tabId), portId, (info && info.name) || ""],
                ext: window.__desireExtID || null
            });
            return makePort((info && info.name) || "", portId);
        },
        onMessage: tabsOnMessage
    };
    // 宿主 → 本页：投递 tabs.sendMessage 的消息（background 发起，回复经 sendReply）。
    window.__desireExt._tabsMessage = function(replyId, msg, sender) {
        tabsOnMessage._dispatch(msg, sender, replyId);
    };
    // 宿主 → 本页：投递 runtime.sendMessage 广播（background → 页面场景，罕见但语义完整）。
    window.__desireExt._runtimeMessage = function(replyId, msg, sender) {
        runtimeOnMessage._dispatch(msg, sender, replyId);
    };
    // 消息传递：onMessage listener 收 (msg, sender, sendResponse)。
    // sendResponse 用返回值同步回复，或返回 true 后异步调 sendResponse。
    var onMessageAPI = function() {
        var cbs = [];
        return {
            addListener: function(cb) {
                cbs.push(cb);
                window.webkit.messageHandlers.desireExt.postMessage({
                    ns: "events", fn: "addListener", args: ["runtime.onMessage"]
                });
            },
            removeListener: function(cb) {
                var i = cbs.indexOf(cb); if (i >= 0) cbs.splice(i, 1);
            },
            _dispatch: function(msg, sender, replyId) {
                var done = false;
                for (var i = 0; i < cbs.length; i++) {
                    (function(cb) {
                        try {
                            var r = cb(msg, sender, function(reply) {
                                if (done) return; done = true;
                                window.webkit.messageHandlers.desireExt.postMessage({
                                    ns: "runtime", fn: "sendReply",
                                    args: [replyId, { ok: true, reply: reply === undefined ? null : reply }],
                                    ext: window.__desireExtID || null
                                });
                            });
                            // 返回 true = 异步回复；否则同步用返回值回复。
                            if (r !== true && !done) {
                                done = true;
                                window.webkit.messageHandlers.desireExt.postMessage({
                                    ns: "runtime", fn: "sendReply",
                                    args: [replyId, { ok: true, reply: r === undefined ? null : r }],
                                    ext: window.__desireExtID || null
                                });
                            }
                        } catch (e) {
                            if (!done) {
                                done = true;
                                window.webkit.messageHandlers.desireExt.postMessage({
                                    ns: "runtime", fn: "sendReply",
                                    args: [replyId, { ok: false, reply: String(e) }],
                                    ext: window.__desireExtID || null
                                });
                            }
                        }
                    })(cbs[i]);
                }
                if (!cbs.length) {
                    // 无人监听：立即告知宿主（宿主据此回复 "no listener"）。
                    window.webkit.messageHandlers.desireExt.postMessage({
                        ns: "runtime", fn: "sendReply",
                        args: [replyId, { ok: false, reply: null, noListener: true }],
                        ext: window.__desireExtID || null
                    });
                }
            }
        };
    };
    var runtimeOnMessage = onMessageAPI();
    var tabsOnMessage = onMessageAPI();

    // Port 长连接：connect() → onConnect（background 侧）；两边都拿 Port 对象
    // {name, postMessage, onMessage, disconnect}。底层走宿主路由（portId 寻址）。
    function makePort(name, portId) {
        var disconnectCbs = [];
        var port = {
            name: name,
            postMessage: function(msg) {
                window.webkit.messageHandlers.desireExt.postMessage({
                    ns: "port", fn: "postMessage", args: [portId, msg === undefined ? null : msg],
                    ext: window.__desireExtID || null
                });
            },
            disconnect: function() {
                // 本端主动断开：先本地 onDisconnect（Chrome 语义），再通知宿主拆对端。
                port._fireDisconnect();
                window.webkit.messageHandlers.desireExt.postMessage({
                    ns: "port", fn: "disconnect", args: [portId],
                    ext: window.__desireExtID || null
                });
            },
            onMessage: {
                addListener: function(cb) {
                    window.__desireExt._portListeners[portId] = (window.__desireExt._portListeners[portId] || []);
                    window.__desireExt._portListeners[portId].push(cb);
                },
                removeListener: function(cb) {
                    var l = window.__desireExt._portListeners[portId] || [];
                    var i = l.indexOf(cb); if (i >= 0) l.splice(i, 1);
                }
            },
            onDisconnect: {
                addListener: function(cb) { disconnectCbs.push(cb); },
                removeListener: function(cb) {
                    var i = disconnectCbs.indexOf(cb); if (i >= 0) disconnectCbs.splice(i, 1);
                }
            },
            _fireDisconnect: function() {
                var ls = disconnectCbs.slice();
                disconnectCbs.length = 0;
                delete window.__desireExt._ports[portId];
                for (var i = 0; i < ls.length; i++) { try { ls[i](port); } catch (e) {} }
            }
        };
        // 注册表：宿主 _portDisconnected 按它找到端口对象并触发 onDisconnect。
        window.__desireExt._ports[portId] = port;
        return port;
    }
    window.__desireExt._portListeners = window.__desireExt._portListeners || {};
    // 端口对象注册表（_portDisconnected 按它找到端口并触发 onDisconnect）。
    window.__desireExt._ports = window.__desireExt._ports || {};
    // 宿主投递 port 消息/断开的入口。
    window.__desireExt._portMessage = function(portId, msg) {
        var l = window.__desireExt._portListeners[portId] || [];
        for (var i = 0; i < l.length; i++) {
            try { l[i](msg); } catch (e) {}
        }
    };
    window.__desireExt._portDisconnected = function(portId) {
        // 对端断开：清消息监听**并**触发本端 onDisconnect（Chrome 语义——
        // 此前只删表，onDisconnect 回调永远不响）。
        delete window.__desireExt._portListeners[portId];
        var port = window.__desireExt._ports && window.__desireExt._ports[portId];
        if (port) port._fireDisconnect();
    };
    // 宿主 → 本页（background 场景）：页面 connect 了，投递 onConnect(port)。
    // **页面还没有 onConnect 监听**（内容脚本未注入/未注册）：立即回报
    // disconnect——Chrome 语义（connect 端马上收到 onDisconnect +
    // "Could not establish connection"，扩展靠它判断内容脚本是否在）。
    window.__desireExt._portConnect = function(portId, name) {
        var cb = window.__desireExt._onConnectCb;
        if (!cb) {
            window.webkit.messageHandlers.desireExt.postMessage({
                ns: "port", fn: "disconnect", args: [portId],
                ext: window.__desireExtID || null
            });
            return;
        }
        try { cb(makePort(name, portId)); } catch (e) {}
    };

    var runtime = {
        id: "desire.webext",
        getManifest: function() {
            return { name: "Desire Extension Runtime", version: "1.0", manifest_version: 3 };
        },
        onInstalled: eventAPI("runtime.onInstalled"),
        // 发消息给本插件的 background 页（promise 回复）。
        sendMessage: function(msg) {
            return rpc("runtime", "sendMessageToBackground", [msg === undefined ? null : msg]);
        },
        onMessage: runtimeOnMessage,
        connect: function(name) {
            // portId 全局唯一（各页面各自的 seq 会撞号，宿主端口表按它寻址）。
            var portId = "port-" + Date.now().toString(36) + "-" + (++seq);
            window.webkit.messageHandlers.desireExt.postMessage({
                ns: "port", fn: "connect",
                args: [portId, name || ""],
                ext: window.__desireExtID || null
            });
            return makePort(name, portId);
        },
        onConnect: {
            addListener: function(cb) {
                window.webkit.messageHandlers.desireExt.postMessage({
                    ns: "events", fn: "addListener", args: ["runtime.onConnect"]
                });
                window.__desireExt._onConnectCb = cb;
            }
        }
    };
    var contextMenus = {
        create: function(props) { return rpc("contextMenus", "create", [props || {}]); },
        remove: function(menuId) { return rpc("contextMenus", "remove", [menuId]); },
        removeAll: function() { return rpc("contextMenus", "removeAll", []); },
        onClicked: eventAPI("contextMenus.onClicked")
    };
    var notifications = {
        create: function(options) { return rpc("notifications", "create", [options || {}]); },
        clear: function(id) { return rpc("notifications", "clear", [id === undefined ? null : String(id)]); }
    };
    var alarms = {
        create: function(name, info) { return rpc("alarms", "create", [name || "", info || {}]); },
        clear: function(name) { return rpc("alarms", "clear", [name || ""]); },
        clearAll: function() { return rpc("alarms", "clearAll", []); },
        get: function(name) { return rpc("alarms", "get", [name || ""]); },
        getAll: function() { return rpc("alarms", "getAll", []); },
        onAlarm: eventAPI("alarms.onAlarm")
    };
    // MV3 动态注入：code|files 注入、insertCSS 注样式。文件来自插件包
    // 资源目录（manifest 包装载时整包拷入；手写插件无文件，files[] 报错）。
    var scripting = {
        executeScript: function(details) { return rpc("scripting", "executeScript", [details || {}]); },
        insertCSS: function(details) { return rpc("scripting", "insertCSS", [details || {}]); },
        // insertCSS 的配对移除（按 css 内容匹配带标记的 style 元素）。
        removeCSS: function(details) { return rpc("scripting", "removeCSS", [details || {}]); }
    };
    // declarativeNetRequest：规则集交宿主编译进 WebKit content blocker
    //（modifyHeaders/requestDomains 等表达不了的规则宿主逐条丢弃，不整包失败）。
    var declarativeNetRequest = {
        updateDynamicRules: function(options) {
            return rpc("declarativeNetRequest", "updateRules", [options || {}, false]);
        },
        updateSessionRules: function(options) {
            return rpc("declarativeNetRequest", "updateRules", [options || {}, true]);
        },
        getDynamicRules: function() { return rpc("declarativeNetRequest", "getRules", [false]); },
        getSessionRules: function() { return rpc("declarativeNetRequest", "getRules", [true]); }
    };
    // MV3 观察语义（无阻塞回调）：宿主把每个网络请求 start/complete 派发进来。
    var webRequest = {
        onBeforeRequest: eventAPI("webRequest.onBeforeRequest"),
        onCompleted: eventAPI("webRequest.onCompleted")
    };
    // cookies（背景/页面 handler 均有宿主实现；remove 宿主按 url+name 删）。
    var cookies = {
        getAll: function(details) { return rpc("cookies", "getAll", [details || {}]); },
        get: function(details) { return rpc("cookies", "get", [details || {}]); },
        set: function(details) { return rpc("cookies", "set", [details || {}]); },
        remove: function(details) { return rpc("cookies", "remove", [details || {}]); }
    };
    var action = {
        setBadgeText: function(details) { return rpc("action", "setBadgeText", [details || {}]); },
        setTitle: function(details) { return rpc("action", "setTitle", [details || {}]); }
    };
    var windows = {
        getAll: function() { return rpc("windows", "getAll", []); },
        create: function(props) { return rpc("windows", "create", [props || {}]); }
    };
    var downloads = {
        download: function(options) { return rpc("downloads", "download", [options || {}]); },
        search: function(query) { return rpc("downloads", "search", [query || {}]); }
    };
    // i18n：宿主在注入 prologue 里内联本插件的 _locales 表
    //（window.__desireI18N，PluginI18N 生成）——getMessage 是同步 API。
    // 无表（手写插件）保持旧降级返回 key 本身；有表缺键 = Chrome 语义空串。
    var i18n = {
        getMessage: function(key, substitutions) {
            var table = window.__desireI18N || null;
            var text;
            if (table && Object.prototype.hasOwnProperty.call(table, String(key))) {
                text = table[String(key)];
            } else if (!table) {
                text = key || "";
            } else {
                text = "";
            }
            if (text && substitutions !== undefined) {
                var subs = Array.isArray(substitutions) ? substitutions : [substitutions];
                text = text.replace(/\$(\d+)/g, function(match, digits) {
                    var idx = parseInt(digits, 10) - 1;
                    return idx >= 0 && idx < subs.length ? String(subs[idx]) : match;
                });
            }
            return text;
        },
        getUILanguage: function() { return navigator.language || "en"; }
    };

    var browser = {
        storage: storage, tabs: tabs, runtime: runtime, notifications: notifications,
        contextMenus: contextMenus, alarms: alarms, action: action,
        windows: windows, downloads: downloads, i18n: i18n, scripting: scripting,
        declarativeNetRequest: declarativeNetRequest, webRequest: webRequest,
        cookies: cookies,
        // 0.3.3：宿主注入的插件身份（只读镜像，调试/判重用）。
        _desireID: function () { return window.__desireExtID || null; },
    };
    window.browser = browser;
    window.chrome = window.chrome || {};
    if (!chrome.storage) chrome.storage = storage;
    if (!chrome.tabs) chrome.tabs = tabs;
    if (!chrome.runtime) chrome.runtime = runtime;
    if (!chrome.notifications) chrome.notifications = notifications;
    if (!chrome.contextMenus) chrome.contextMenus = contextMenus;
    if (!chrome.alarms) chrome.alarms = alarms;
    if (!chrome.action) chrome.action = action;
    if (!chrome.windows) chrome.windows = windows;
    if (!chrome.downloads) chrome.downloads = downloads;
    if (!chrome.i18n) chrome.i18n = i18n;
    if (!chrome.scripting) chrome.scripting = scripting;
    if (!chrome.declarativeNetRequest) chrome.declarativeNetRequest = declarativeNetRequest;
    if (!chrome.webRequest) chrome.webRequest = webRequest;
    if (!chrome.cookies) chrome.cookies = cookies;
})();
