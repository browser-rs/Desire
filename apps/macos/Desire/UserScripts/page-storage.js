// page-storage.js — Application 页签的数据源：IndexedDB / Cache Storage /
// Service Worker（localStorage / sessionStorage 走 DevToolsStore 里的内联脚本）。
//
// 用法：`callAsyncJavaScript(script, arguments: ["mode": …, …])` —— 形参名必须与
// 字典键一致（见 AGENTS.md 的 callAsyncJavaScript 约定），所以这里直接按名使用。
//
// 全部只读列举 + 删除；返回值一律是 JSON 字符串（原生侧解码）。
return (async function() {
    function json(value) { return JSON.stringify(value); }

    // ── IndexedDB ───────────────────────────────────────────────────────────
    // `indexedDB.databases()` 给出源下的库名与版本（Safari 14+）；逐个 open
    // 只读列举对象存储与条数。**不带版本号 open**，避免触发 upgradeneeded。
    if (mode === 'idb-list') {
        if (!window.indexedDB || !indexedDB.databases) return json({ stores: [], unsupported: true });
        var databases = [];
        try { databases = await indexedDB.databases(); } catch (e) { return json({ stores: [], error: String(e) }); }
        var stores = [];
        for (var d = 0; d < databases.length; d++) {
            var info = databases[d];
            if (!info || !info.name) continue;
            var db = await new Promise(function(resolve) {
                var request;
                try { request = indexedDB.open(info.name); } catch (e) { resolve(null); return; }
                request.onsuccess = function() { resolve(request.result); };
                request.onerror = function() { resolve(null); };
                request.onblocked = function() { resolve(null); };
            });
            if (!db) continue;
            var names = Array.prototype.slice.call(db.objectStoreNames);
            for (var s = 0; s < names.length; s++) {
                var count = await new Promise(function(resolve) {
                    try {
                        var tx = db.transaction(names[s], 'readonly');
                        var request = tx.objectStore(names[s]).count();
                        request.onsuccess = function() { resolve(request.result || 0); };
                        request.onerror = function() { resolve(0); };
                    } catch (e) { resolve(0); }
                });
                stores.push({ database: db.name, version: db.version, name: names[s], count: count });
            }
            db.close();
        }
        return json({ stores: stores });
    }

    if (mode === 'idb-delete') {
        var deleted = await new Promise(function(resolve) {
            try {
                var request = indexedDB.deleteDatabase(name);
                request.onsuccess = function() { resolve(true); };
                request.onerror = function() { resolve(false); };
                request.onblocked = function() { resolve(false); };
            } catch (e) { resolve(false); }
        });
        return json({ ok: deleted });
    }

    // ── Cache Storage ───────────────────────────────────────────────────────
    if (mode === 'cache-list') {
        if (!window.caches) return json({ entries: [] });
        var cacheNames = [];
        try { cacheNames = await caches.keys(); } catch (e) { return json({ entries: [], error: String(e) }); }
        var entries = [];
        var cap = Math.max(1, Math.min(limit || 300, 1000));
        for (var c = 0; c < cacheNames.length && entries.length < cap; c++) {
            var cache = await caches.open(cacheNames[c]);
            var requests = await cache.keys();
            for (var r = 0; r < requests.length && entries.length < cap; r++) {
                entries.push({ cache: cacheNames[c], url: requests[r].url, method: requests[r].method || 'GET' });
            }
        }
        return json({ entries: entries, caches: cacheNames.length });
    }

    if (mode === 'cache-delete') {
        var opened = await caches.open(cacheName);
        var removed = await opened.delete(url);
        return json({ ok: !!removed });
    }

    if (mode === 'cache-clear') {
        var names = await caches.keys();
        for (var i = 0; i < names.length; i++) { await caches.delete(names[i]); }
        return json({ ok: true, removed: names.length });
    }

    // ── Service Worker ──────────────────────────────────────────────────────
    if (mode === 'sw-list') {
        if (!navigator.serviceWorker) return json({ workers: [] });
        var registrations = await navigator.serviceWorker.getRegistrations();
        var workers = registrations.map(function(registration) {
            var worker = registration.active || registration.waiting || registration.installing || {};
            return {
                scope: registration.scope,
                scriptURL: worker.scriptURL || '',
                state: worker.state || 'unknown'
            };
        });
        return json({ workers: workers });
    }

    if (mode === 'sw-unregister') {
        // 注意：`callAsyncJavaScript` 的形参**只在字典里传了才存在**——没传
        // `scope` 时直接引用它会 ReferenceError，所以这里必须 typeof 兜底
        // （其余分支的参数都由原生侧无条件传入）。
        var wanted = (typeof scope === 'undefined') ? '' : scope;
        var all = await navigator.serviceWorker.getRegistrations();
        var count = 0;
        for (var k = 0; k < all.length; k++) {
            if (wanted && all[k].scope !== wanted) continue;
            if (await all[k].unregister()) count++;
        }
        return json({ ok: true, unregistered: count, total: all.length });
    }

    return json({ error: 'unknown mode: ' + mode });
})();
