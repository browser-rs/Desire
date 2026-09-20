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

    // 发起者（面板详情的 Initiator）：调用栈里第一条**页面自己的** http(s) 帧，
    // 返回 `url:行`。跳过本脚本自己的帧；拿不到就是 null（资源计时的条目没有
    // 调用栈，只有 fetch/XHR/WS 这类被钩住的才有）。
    function callerFrame() {
        try {
            var lines = (new Error().stack || '').split('\n');
            for (var i = 1; i < lines.length; i++) {
                var match = lines[i].match(/https?:\/\/[^\s)]+:\d+:\d+/);
                if (!match) continue;
                var text = match[0];
                if (text.indexOf('network-monitor') >= 0) continue;
                // 去掉尾部坐标（按最后两个冒号，别按第一个——见 console-intercept.js）。
                var tail = text.match(/:(\d+):(\d+)$/);
                if (tail) text = text.slice(0, text.length - tail[0].length) + ':' + tail[1];
                return text;
            }
        } catch (e) {}
        return null;
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
                   requestBody: clip(init && init.body), initiator: callerFrame() });
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
                       resourceType: 'xhr', requestBody: clip(body), initiator: callerFrame() });
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

    // ④ WebSocket / SSE：连接 + 双向消息帧。
    //
    // 这两类没有响应体可以"读一次"，它们是一条一直开着的流，所以模型不一样：
    // 连接本身是一条请求（start → complete，状态 101 / 200），每条消息是一帧
    // （phase:'frame'，direction in/out/system）。面板详情里按帧列表展示。
    function postFrame(id, url, resourceType, direction, payload, extra) {
        var event = {
            phase: 'frame', jsId: id, url: url, resourceType: resourceType,
            direction: direction, payload: clip(payload)
        };
        if (extra) { for (var key in extra) { event[key] = extra[key]; } }
        post(event);
    }

    var NativeWS = window.WebSocket;
    if (NativeWS) {
        // 包装构造函数（返回原生实例，保持 instanceof 与常量）。
        var Wrapped = function(url, protocols) {
            var socket = arguments.length > 1 ? new NativeWS(url, protocols) : new NativeWS(url);
            try { instrumentSocket(socket, absolute(url)); } catch (e) {}
            return socket;
        };
        Wrapped.prototype = NativeWS.prototype;
        Wrapped.CONNECTING = NativeWS.CONNECTING;
        Wrapped.OPEN = NativeWS.OPEN;
        Wrapped.CLOSING = NativeWS.CLOSING;
        Wrapped.CLOSED = NativeWS.CLOSED;
        window.WebSocket = Wrapped;
    }

    function instrumentSocket(socket, url) {
        var id = newId();
        var startedAt = performance.now();
        hooked[url] = Date.now();
        post({ phase: 'start', jsId: id, url: url, method: 'GET', resourceType: 'websocket',
               streaming: true, initiator: callerFrame() });
        socket.addEventListener('open', function() {
            post({ phase: 'complete', jsId: id, url: url, method: 'GET', resourceType: 'websocket',
                   status: 101, responseHeaders: socket.protocol ? { 'sec-websocket-protocol': socket.protocol } : {},
                   duration: (performance.now() - startedAt) / 1000, streaming: true });
        });
        socket.addEventListener('message', function(event) {
            var data = event && event.data;
            postFrame(id, url, 'websocket', 'in',
                      typeof data === 'string' ? data : ('[binary ' + ((data && data.byteLength) || 0) + ' bytes]'));
        });
        socket.addEventListener('close', function(event) {
            postFrame(id, url, 'websocket', 'system',
                      'closed' + (event && event.code ? ' (' + event.code + ')' : ''));
        });
        socket.addEventListener('error', function() {
            postFrame(id, url, 'websocket', 'system', 'error');
        });
        var originalSend = socket.send;
        socket.send = function(data) {
            try {
                postFrame(id, url, 'websocket', 'out',
                          typeof data === 'string' ? data : ('[binary ' + ((data && data.byteLength) || 0) + ' bytes]'));
            } catch (e) {}
            return originalSend.apply(socket, arguments);
        };
    }

    var NativeES = window.EventSource;
    if (NativeES) {
        var WrappedES = function(url, config) {
            var source = config === undefined ? new NativeES(url) : new NativeES(url, config);
            try {
                var abs = absolute(url);
                var id = newId();
                var startedAt = performance.now();
                hooked[abs] = Date.now();
                post({ phase: 'start', jsId: id, url: abs, method: 'GET', resourceType: 'other',
                       streaming: true, initiator: callerFrame() });
                source.addEventListener('open', function() {
                    post({ phase: 'complete', jsId: id, url: abs, method: 'GET', resourceType: 'other',
                           status: 200, mimeType: 'text/event-stream',
                           duration: (performance.now() - startedAt) / 1000, streaming: true });
                });
                source.addEventListener('message', function(event) {
                    postFrame(id, abs, 'other', 'in', (event && event.data) || '');
                });
                source.addEventListener('error', function() {
                    postFrame(id, abs, 'other', 'system', 'error');
                });
            } catch (e) {}
            return source;
        };
        WrappedES.prototype = NativeES.prototype;
        WrappedES.CONNECTING = NativeES.CONNECTING;
        WrappedES.OPEN = NativeES.OPEN;
        WrappedES.CLOSED = NativeES.CLOSED;
        window.EventSource = WrappedES;
    }
})();
