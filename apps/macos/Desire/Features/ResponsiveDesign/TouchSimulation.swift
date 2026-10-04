import WebKit

/// Synthesizes touch events from mouse events so mobile-only UI (touchstart/
/// touchmove/touchend listeners) responds in responsive mode. All state
/// lives under one registry object so `remove` can undo EVERYTHING — the
/// previous version left its listeners and global CSS on the page forever
/// (text selection permanently broken after one toggle).
enum TouchSimulation {
    static func apply(to webView: WKWebView) {
        webView.evaluateJavaScript(applyJS, completionHandler: nil)
    }

    static func remove(from webView: WKWebView) {
        webView.evaluateJavaScript(removeJS, completionHandler: nil)
    }

    static let applyJS = """
    (function() {
        if (window.__desireTouchSim) return;
        var seq = 0;
        function makeTouch(e) {
            return new Touch({
                identifier: ++seq,
                target: e.target,
                clientX: e.clientX, clientY: e.clientY,
                screenX: e.screenX, screenY: e.screenY,
                pageX: e.pageX, pageY: e.pageY,
                radiusX: 12, radiusY: 12, rotationAngle: 0, force: 1
            });
        }
        function ripple(x, y) {
            var dot = document.createElement('div');
            dot.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;'
                + 'width:36px;height:36px;border-radius:50%;'
                + 'background:rgba(0,122,255,0.3);border:2px solid rgba(0,122,255,0.6);'
                + 'transform:translate(-50%,-50%);left:' + x + 'px;top:' + y + 'px;';
            document.body.appendChild(dot);
            dot.animate([{ transform: 'translate(-50%,-50%) scale(0.5)', opacity: 1 },
                         { transform: 'translate(-50%,-50%) scale(1.6)', opacity: 0 }],
                        { duration: 450 });
            setTimeout(function() { dot.remove(); }, 460);
        }
        var api = {
            onStart: function(e) {
                var t = makeTouch(e);
                e.target.dispatchEvent(new TouchEvent('touchstart', {
                    cancelable: true, bubbles: true,
                    touches: [t], targetTouches: [t], changedTouches: [t]
                }));
                if (document.body) ripple(e.clientX, e.clientY);
            },
            onMove: function(e) {
                if (e.buttons === 0) return;
                var t = makeTouch(e);
                e.target.dispatchEvent(new TouchEvent('touchmove', {
                    cancelable: true, bubbles: true,
                    touches: [t], targetTouches: [t], changedTouches: [t]
                }));
            },
            onEnd: function(e) {
                var t = makeTouch(e);
                e.target.dispatchEvent(new TouchEvent('touchend', {
                    cancelable: true, bubbles: true,
                    touches: [], targetTouches: [], changedTouches: [t]
                }));
            }
        };
        window.__desireTouchSim = api;
        document.addEventListener('mousedown', api.onStart, true);
        document.addEventListener('mousemove', api.onMove, true);
        document.addEventListener('mouseup', api.onEnd, true);
        var style = document.createElement('style');
        style.setAttribute('data-desire-touch', '');
        style.textContent = '* { cursor: crosshair !important; touch-action: none; -webkit-touch-callout: none; }';
        document.head.appendChild(style);
    })();
    """

    static let removeJS = """
    (function() {
        var api = window.__desireTouchSim;
        if (api) {
            document.removeEventListener('mousedown', api.onStart, true);
            document.removeEventListener('mousemove', api.onMove, true);
            document.removeEventListener('mouseup', api.onEnd, true);
            window.__desireTouchSim = null;
        }
        document.querySelectorAll('style[data-desire-touch]').forEach(function(s) { s.remove(); });
    })();
    """
}
