import AppKit
import SwiftUI
import WebKit

/// 电子书正文 WebView（v0.8.34）：本地章节文件 + 只读访问书根目录；
/// 滚动比例经 script message 回传，阅读器据此保存进度。
struct EbookWebView: NSViewRepresentable {
    let fileURL: URL?
    let bookRoot: URL
    let onReady: (WKWebView) -> Void
    let onProgress: (Double) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "ebookProgress")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let fileURL else { return }
        if context.coordinator.loadedURL != fileURL {
            context.coordinator.loadedURL = fileURL
            webView.loadFileURL(fileURL, allowingReadAccessTo: bookRoot)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onProgress: onProgress)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onReady: (WKWebView) -> Void
        let onProgress: (Double) -> Void
        var loadedURL: URL?

        init(onReady: @escaping (WKWebView) -> Void,
             onProgress: @escaping (Double) -> Void) {
            self.onReady = onReady
            self.onProgress = onProgress
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onReady(webView)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "ebookProgress",
                  let value = message.body as? NSNumber else { return }
            onProgress(value.doubleValue)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.isFileURL {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
