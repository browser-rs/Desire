import Foundation
import WebKit

/// devicePixelRatio 覆写（0.6.6 响应式收尾）：页面 JS 读
/// `window.devicePixelRatio` 时返回模拟值——此前 ResponsiveConfig.pixelRatio
/// 只是工具栏文案（"@2x"），从未生效。defineProperty configurable，remove 时
/// 按保存的原描述符还原（Safari 上 devicePixelRatio 是 window 自有属性）。
enum PixelRatioOverride {
    static func apply(_ value: Double, to webView: WKWebView) {
        webView.evaluateJavaScript(applyJS(value: value), completionHandler: nil)
    }

    static func remove(from webView: WKWebView) {
        webView.evaluateJavaScript(removeJS, completionHandler: nil)
    }

    static func applyJS(value: Double) -> String {
        """
        (function () {
            if (!window.__desireOriginalDPR) {
                window.__desireOriginalDPR = Object.getOwnPropertyDescriptor(window, 'devicePixelRatio');
            }
            Object.defineProperty(window, 'devicePixelRatio', {
                get: function () { return \(value); },
                configurable: true
            });
            return window.devicePixelRatio;
        })();
        """
    }

    static let removeJS = """
    (function () {
        var saved = window.__desireOriginalDPR;
        if (saved) {
            Object.defineProperty(window, 'devicePixelRatio', saved);
            window.__desireOriginalDPR = null;
        }
        return window.devicePixelRatio;
    })();
    """
}
