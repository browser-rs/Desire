// console-intercept.js
// Source: Desire/Features/Browsing/WebView.swift (BrowserState.init, consoleJS)
// Injected as: WKUserScript @ atDocumentStart, forMainFrameOnly: false
// Wraps console.{log,warn,error,info,debug} and the global error event,
// forwarding each message (with source line/column/url when available) to
// the `devConsole` message handler consumed by the DevTools console panel.
(function() {
    var originalConsole = {
        log: console.log,
        warn: console.warn,
        error: console.error,
        info: console.info,
        debug: console.debug
    };
    // 对象句柄表：面板点开一个对象时按句柄回页面取属性（一层，可继续展开）。
    // 值本身留在页面里（原生侧拿不到活对象），所以有上限、FIFO 淘汰。
    var MAX_REFS = 300;
    var refs = new Map();
    var nextRef = 0;

    function registerRef(value) {
        var id = 'c' + (++nextRef);
        refs.set(id, value);
        if (refs.size > MAX_REFS) {
            refs.delete(refs.keys().next().value);
        }
        return id;
    }

    // 值的短预览：对象给前几个键，DOM 元素给标签，数组/NodeList 给长度。
    // （此前这里直接 JSON.stringify，于是 console.log(document.body) 只显示
    // "{}"——元素没有可枚举自有属性。）
    function previewOf(value) {
        try {
            if (value === null) return 'null';
            var type = typeof value;
            if (type === 'string') return JSON.stringify(value.length > 60 ? value.slice(0, 60) + '…' : value);
            if (type === 'number' || type === 'boolean' || type === 'undefined') return String(value);
            if (type === 'function') return 'ƒ ' + (value.name || 'anonymous') + '()';
            if (value.nodeType === 1) {
                var tag = value.tagName.toLowerCase();
                var id = value.id ? '#' + value.id : '';
                var cls = (value.classList && value.classList.length) ? '.' + Array.prototype.slice.call(value.classList, 0, 2).join('.') : '';
                return '<' + tag + id + cls + '>';
            }
            if (Array.isArray(value)) return 'Array(' + value.length + ')';
            if (typeof NodeList !== 'undefined' && value instanceof NodeList) return 'NodeList(' + value.length + ')';
            if (value instanceof Date) return value.toISOString();
            if (value instanceof Error) return value.name + ': ' + value.message;
            var ctor = (value.constructor && value.constructor.name) || 'Object';
            var keys = Object.keys(value);
            var head = keys.slice(0, 3).map(function(key) {
                var item = value[key];
                var kind = typeof item;
                var text = item === null ? 'null'
                    : kind === 'object' ? (Array.isArray(item) ? 'Array(' + item.length + ')'
                        : (item && item.nodeType === 1 ? '<' + item.tagName.toLowerCase() + '>' : '{…}'))
                    : kind === 'string' ? JSON.stringify(item).slice(0, 20)
                    : String(item);
                return key + ': ' + text;
            }).join(', ');
            return ctor + ' {' + head + (keys.length > 3 ? ', …' : '') + '}';
        } catch (e) { return String(value); }
    }

    function refWorthy(value) {
        return value !== null && (typeof value === 'object' || typeof value === 'function');
    }

    // 原生侧按句柄取属性（一层）：`window.__desireConsole.describe('c7')`。
    window.__desireConsole = {
        describe: function(ref) {
            var value = refs.get(ref);
            if (value === undefined) return JSON.stringify({ error: 'handle expired' });
            // DOM 元素没有可枚举自有属性（`Object.keys(el)` 是空的），所以单独
            // 给一组排查时真会看的字段：标签/id/class/属性/文本 + 前几个子元素
            // （子元素带句柄，可以继续点开）。
            if (value.nodeType === 1) {
                var elementProps = [
                    { name: 'tagName', preview: value.tagName.toLowerCase(), ref: null },
                    { name: 'id', preview: JSON.stringify(value.id), ref: null },
                    { name: 'className', preview: JSON.stringify(String(value.className)), ref: null },
                    { name: 'childElementCount', preview: String(value.childElementCount), ref: null },
                    { name: 'textContent', preview: previewOf((value.textContent || '').trim().slice(0, 80)), ref: null }
                ];
                Array.prototype.slice.call(value.attributes).forEach(function(attr) {
                    elementProps.push({ name: '@' + attr.name, preview: JSON.stringify(attr.value), ref: null });
                });
                Array.prototype.slice.call(value.children, 0, 10).forEach(function(child, index) {
                    elementProps.push({ name: '[' + index + ']', preview: previewOf(child), ref: registerRef(child) });
                });
                return JSON.stringify({
                    ctor: value.tagName.toLowerCase(),
                    preview: previewOf(value),
                    props: elementProps
                });
            }
            var props = [];
            try {
                Object.keys(value).slice(0, 100).forEach(function(key) {
                    var item;
                    try { item = value[key]; } catch (e) { props.push({ name: key, preview: '[getter threw]', ref: null }); return; }
                    props.push({
                        name: key,
                        preview: previewOf(item),
                        ref: refWorthy(item) ? registerRef(item) : null
                    });
                });
            } catch (e) {}
            return JSON.stringify({
                ctor: (value.constructor && value.constructor.name) || typeof value,
                preview: previewOf(value),
                props: props
            });
        }
    };

    function sendToDevTools(level, args) {
        try {
            var parts = [];
            var texts = [];
            Array.prototype.slice.call(args).forEach(function(arg) {
                if (refWorthy(arg)) {
                    var preview = previewOf(arg);
                    parts.push({ type: 'object', ref: registerRef(arg), preview: preview });
                    texts.push(preview);
                } else {
                    var text = String(arg);
                    parts.push({ type: 'text', text: text });
                    texts.push(text);
                }
            });
            var message = texts.join(' ');
            var stack = new Error().stack;
            var line = null, col = null, url = null;
            if (stack) {
                // 取第一帧里的 `…/file.js:行:列`，尾部坐标按**最后**两个冒号拆。
                // （曾经写成按第一个冒号切，于是每个 https 页面的来源都退化成
                // 协议名 "https"——面板的来源列全页显示 "https"。）
                var frame = stack.match(/https?:\/\/[^\s)]+:\d+:\d+/) || stack.match(/https?:\/\/[^\s)]+/);
                if (frame) {
                    var text = frame[0];
                    var tail = text.match(/:(\d+):(\d+)$/);
                    if (tail) {
                        line = parseInt(tail[1], 10);
                        col = parseInt(tail[2], 10);
                        text = text.slice(0, text.length - tail[0].length);
                    }
                    // 行内脚本/扩展页的来源是 about:blank 之类，不可用时保持 null。
                    url = /^https?:/.test(text) ? text : null;
                }
            }
            window.webkit.messageHandlers.devConsole.postMessage({
                level: level,
                message: message,
                parts: parts,
                url: url,
                line: line,
                column: col
            });
        } catch(e) {}
    }
    console.log = function() { sendToDevTools('log', arguments); originalConsole.log.apply(console, arguments); };
    console.warn = function() { sendToDevTools('warn', arguments); originalConsole.warn.apply(console, arguments); };
    console.error = function() { sendToDevTools('error', arguments); originalConsole.error.apply(console, arguments); };
    console.info = function() { sendToDevTools('info', arguments); originalConsole.info.apply(console, arguments); };
    console.debug = function() { sendToDevTools('debug', arguments); originalConsole.debug.apply(console, arguments); };
    window.addEventListener('error', function(e) {
        sendToDevTools('error', [e.message]);
    });
})();
