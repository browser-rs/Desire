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
    function sendToDevTools(level, args) {
        try {
            var message = Array.from(args).map(function(arg) {
                if (typeof arg === 'object') {
                    try { return JSON.stringify(arg); }
                    catch(e) { return String(arg); }
                }
                return String(arg);
            }).join(' ');
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
