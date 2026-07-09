import WebKit

enum TouchSimulation {
    static let css = "* { cursor: crosshair !important; touch-action: none; -webkit-touch-callout: none; user-select: none; }"

    static let js = """
    (function() {
        if (window._desireTouchSimActive) return;
        window._desireTouchSimActive = true;

        function createRipple(x, y) {
            const dot = document.createElement('div');
            dot.style.cssText = 'position:fixed;pointer-events:none;z-index:99999;width:40px;height:40px;border-radius:50%;background:rgba(0,122,255,0.3);border:2px solid rgba(0,122,255,0.6);transform:translate(-50%,-50%);left:'+x+'px;top:'+y+'px;animation:desireRipple 0.6s ease-out forwards;';
            document.body.appendChild(dot);
            setTimeout(() => dot.remove(), 600);
        }

        const style = document.createElement('style');
        style.textContent = '@keyframes desireRipple { 0% { transform: translate(-50%,-50%) scale(0.5); opacity:1; } 100% { transform: translate(-50%,-50%) scale(1.5); opacity:0; } }';
        document.head.appendChild(style);

        document.addEventListener('mousedown', e => {
            const touch = new Touch({ identifier: Date.now(), target: e.target, clientX: e.clientX, clientY: e.clientY });
            const event = new TouchEvent('touchstart', { cancelable: true, bubbles: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] });
            e.target.dispatchEvent(event);
            createRipple(e.clientX, e.clientY);
        }, true);

        document.addEventListener('mousemove', e => {
            if (e.buttons === 0) return;
            const touch = new Touch({ identifier: Date.now(), target: e.target, clientX: e.clientX, clientY: e.clientY });
            const event = new TouchEvent('touchmove', { cancelable: true, bubbles: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] });
            e.target.dispatchEvent(event);
        }, true);

        document.addEventListener('mouseup', e => {
            const touch = new Touch({ identifier: Date.now(), target: e.target, clientX: e.clientX, clientY: e.clientY });
            const event = new TouchEvent('touchend', { cancelable: true, bubbles: true, touches: [], targetTouches: [], changedTouches: [touch] });
            e.target.dispatchEvent(event);
        }, true);
    })();
    """

    static let revertJS = "window._desireTouchSimActive = false;"

    static func apply(to webView: WKWebView) {
        let cssInject = "var s = document.createElement('style'); s.textContent = '\(css)'; document.head.appendChild(s);"
        webView.evaluateJavaScript(cssInject, completionHandler: nil)
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    static func remove(from webView: WKWebView) {
        webView.evaluateJavaScript(revertJS, completionHandler: nil)
    }
}
