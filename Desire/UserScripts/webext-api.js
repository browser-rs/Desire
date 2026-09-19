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

    function rpc(ns, fn, args) {
        return new Promise(function(resolve, reject) {
            var id = ++seq;
            pending[id] = { resolve: resolve, reject: reject };
            window.webkit.messageHandlers.desireExt.postMessage({
                id: id, ns: ns, fn: fn, args: args || []
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
        // Swift fans tab events out to registered listeners.
        _fire: function(event, payload) {
            (listeners[event] || []).forEach(function(cb) {
                try { cb(payload); } catch (e) { /* listener error is its own */ }
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
            }
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
        }
    };
    var tabs = {
        query: function() { return rpc("tabs", "query", []); },
        create: function(props) { return rpc("tabs", "create", [props || {}]); },
        remove: function(ids) { return rpc("tabs", "remove", [ids]); },
        onCreated: eventAPI("tabs.onCreated"),
        onRemoved: eventAPI("tabs.onRemoved"),
        onActivated: eventAPI("tabs.onActivated")
    };
    var runtime = {
        id: "desire.webext",
        getManifest: function() {
            return { name: "Desire Extension Runtime", version: "1.0", manifest_version: 3 };
        }
    };
    var notifications = {
        create: function(options) { return rpc("notifications", "create", [options || {}]); }
    };

    var browser = { storage: storage, tabs: tabs, runtime: runtime, notifications: notifications };
    window.browser = browser;
    window.chrome = window.chrome || {};
    if (!chrome.storage) chrome.storage = storage;
    if (!chrome.tabs) chrome.tabs = tabs;
    if (!chrome.runtime) chrome.runtime = runtime;
    if (!chrome.notifications) chrome.notifications = notifications;
})();
