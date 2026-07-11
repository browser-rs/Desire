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
                var match = stack.match(/:(\d+):(\d+)/);
                if (match) { line = parseInt(match[1]); col = parseInt(match[2]); }
                var urlMatch = stack.match(/https?:\/\/[^\s]+/);
                if (urlMatch) { url = urlMatch[0].split(':')[0]; }
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
