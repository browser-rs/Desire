// network-monitor.js — DevTools ▸ Network 页签的子资源数据源
// Injected as: WKUserScript @ atDocumentStart (main frame + subframes)
//
// WebKit 没有公开的"所有请求"回调（`WKNavigationDelegate` 只给导航），所以这里
// 用页面侧的两条来源拼出可用的网络视图：
//   ① PerformanceObserver('resource')：覆盖**所有**子资源（含缓存命中）的
//      URL / 类型 / 耗时 / 传输字节 / 响应状态，但没有请求方法；
//   ② fetch / XMLHttpRequest 钩子：补上方法、状态、请求头、响应头与截断的
//      body —— 这些是排查接口问题时真正要看的东西。
// 两条来源按 URL 去重（②报过的 URL，①在 2 秒内不再重复上报）。
//
// 上报格式见 `DevToolsStore.applyNetworkEvent`：
//   { phase: "start"|"complete"|"body", jsId?, url, method?, resourceType,
//     status?, duration?, size?, requestBody?, responseHeaders?, responseBody? }
(function() {
    if (window.__desireNetMon) return;
    window.__desireNetMon = true;

    var MAX_BODY = 4096;
    var DEDUPE_MS = 2000;

    function post(payload) {
        try {
            window.webkit.messageHandlers.netEntry.postMessage(payload);
        } catch (e) {}
    }

    function clip(value) {
        if (value == null) return null;
        var text = typeof value === 'string' ? value : String(value);
        return text.length > MAX_BODY ? text.slice(0, MAX_BODY) : text;
    }

    function typeOf(initiator) {
        switch ((initiator || '').toLowerCase()) {
            case 'script': return 'script';
            case 'link': case 'css': return 'stylesheet';
            case 'img': case 'image': case 'imageset': return 'image';
            case 'fetch': return 'fetch';
            case 'xmlhttprequest': return 'xhr';
            case 'video': case 'audio': return 'media';
            case 'beacon': return 'other';
            default: return 'other';
        }
    }

    function absolute(url) {
        try { return new URL(url, location.href).href; } catch (e) { return String(url || ''); }
    }

    // ② 报过的 URL（去重用）：url → 时间戳
    var hooked = {};

    // ① 资源计时
    try {
        var observer = new PerformanceObserver(function(list) {
            list.getEntries().forEach(function(entry) {
                if (!entry || !entry.name) return;
                var seen = hooked[entry.name];
                if (seen && Date.now() - seen < DEDUPE_MS) return;
                // 资源计时的分段（能拿到就带上：DNS / TCP / TLS / 首字节 / 下载）
                var timing = null;
                if (entry.responseEnd > 0) {
                    var ms = function(a, b) { return (a > 0 && b >= a) ? (b - a) / 1000 : null; };
                    timing = {
                        dns: ms(entry.domainLookupStart, entry.domainLookupEnd),
                        connect: ms(entry.connectStart, entry.connectEnd),
                        tls: entry.secureConnectionStart > 0 ? ms(entry.secureConnectionStart, entry.connectEnd) : null,
                        ttfb: ms(entry.requestStart, entry.responseStart),
                        download: ms(entry.responseStart, entry.responseEnd),
                        blocked: ms(entry.startTime, entry.requestStart)
                    };
                }
                post({
                    phase: 'complete',
                    url: entry.name,
                    resourceType: typeOf(entry.initiatorType),
                    duration: entry.duration / 1000,
                    size: entry.transferSize || entry.encodedBodySize || 0,
                    status: entry.responseStatus || null,
                    method: null,
                    timing: timing,
                    // transferSize 为 0 但解出了内容 = 命中缓存（性能排查的关键信号）
                    fromCache: entry.transferSize === 0 && (entry.decodedBodySize || 0) > 0
                });
            });
        });
        observer.observe({ type: 'resource', buffered: true });
    } catch (e) {}

    var nextId = 0;
    function newId() { return 'js' + (++nextId) + '-' + Date.now(); }

    // ② fetch
    if (typeof window.fetch === 'function') {
        var originalFetch = window.fetch;
        window.fetch = function(input, init) {
            var url = absolute(typeof input === 'string' ? input : (input && input.url) || '');
            var method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
            var id = newId();
            var startedAt = performance.now();
            hooked[url] = Date.now();
            post({ phase: 'start', jsId: id, url: url, method: method, resourceType: 'fetch',
                   requestBody: clip(init && init.body) });
            var promise = originalFetch.apply(this, arguments);
            promise.then(function(response) {
                var headers = {};
                try { response.headers.forEach(function(value, key) { headers[key] = value; }); } catch (e) {}
                var wall = (performance.now() - startedAt) / 1000;
                post({ phase: 'complete', jsId: id, url: url, method: method, resourceType: 'fetch',
                       status: response.status, responseHeaders: headers, duration: wall,
                       timing: { ttfb: wall, download: 0 } });
                try {
                    response.clone().text().then(function(text) {
                        post({ phase: 'body', jsId: id, url: url, resourceType: 'fetch',
                               responseBody: clip(text) });
                    }, function() {});
                } catch (e) {}
            }, function(error) {
                post({ phase: 'complete', jsId: id, url: url, method: method, resourceType: 'fetch',
                       status: 0, responseHeaders: {}, responseBody: clip(String(error)) });
            });
            return promise;
        };
    }

    // ③ XMLHttpRequest
    var XHR = window.XMLHttpRequest;
    if (XHR && XHR.prototype) {
        var open = XHR.prototype.open;
        var send = XHR.prototype.send;
        var setHeader = XHR.prototype.setRequestHeader;
        XHR.prototype.open = function(method, url) {
            this.__desireNet = {
                method: String(method || 'GET').toUpperCase(),
                url: absolute(url),
                id: newId(),
                headers: {}
            };
            return open.apply(this, arguments);
        };
        XHR.prototype.setRequestHeader = function(name, value) {
            try { if (this.__desireNet) this.__desireNet.headers[String(name)] = String(value); } catch (e) {}
            return setHeader.apply(this, arguments);
        };
        XHR.prototype.send = function(body) {
            var meta = this.__desireNet;
            if (meta) {
                meta.startedAt = performance.now();
                hooked[meta.url] = Date.now();
                post({ phase: 'start', jsId: meta.id, url: meta.url, method: meta.method,
                       resourceType: 'xhr', requestBody: clip(body) });
                var xhr = this;
                xhr.addEventListener('loadend', function() {
                    var headers = {};
                    try {
                        (xhr.getAllResponseHeaders() || '').split(/\r?\n/).forEach(function(line) {
                            var index = line.indexOf(':');
                            if (index > 0) headers[line.slice(0, index).trim().toLowerCase()] = line.slice(index + 1).trim();
                        });
                    } catch (e) {}
                    var wall = meta.startedAt ? (performance.now() - meta.startedAt) / 1000 : null;
                    post({ phase: 'complete', jsId: meta.id, url: meta.url, method: meta.method,
                           resourceType: 'xhr', status: xhr.status, responseHeaders: headers,
                           duration: wall, timing: wall ? { ttfb: wall, download: 0 } : null });
                    if (xhr.responseType === '' || xhr.responseType === 'text') {
                        try {
                            post({ phase: 'body', jsId: meta.id, url: meta.url, resourceType: 'xhr',
                                   responseBody: clip(xhr.responseText) });
                        } catch (e) {}
                    }
                });
            }
            return send.apply(this, arguments);
        };
    }
})();
