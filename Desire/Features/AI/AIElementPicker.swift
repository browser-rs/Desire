import WebKit

struct AIElementPicker {
    static func extractHTML(selector: String, webView: WKWebView, completion: @escaping (String) -> Void) {
        let escaped = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("""
        (function() {
            var el = document.querySelector('\(escaped)');
            return el ? el.outerHTML.substring(0, 2000) : '';
        })()
        """) { result, _ in
            completion((result as? String) ?? "")
        }
    }
}
