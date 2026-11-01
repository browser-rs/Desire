import AppKit
import SwiftUI
import WebKit

/// 电子书正文 WebView（v0.8.34）：本地章节文件 + 只读访问书根目录；
/// 滚动比例/分页结果经 script message 回传；翻页动画由分页 HTML 的 CSS 3D 完成。
struct EbookWebView: NSViewRepresentable {
    let fileURL: URL?
    let bookRoot: URL
    let pageTurn: EbookPageTurnRequest?
    let onReady: (WKWebView) -> Void
    let onProgress: (Double) -> Void
    let onPages: (Int, Int) -> Void
    let onSelection: (EbookSelection) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "ebookProgress")
        configuration.userContentController.add(context.coordinator, name: "ebookPages")
        configuration.userContentController.add(context.coordinator, name: "ebookSelection")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let fileURL else { return }
        if context.coordinator.loadedURL != fileURL {
            context.coordinator.loadedURL = fileURL
            webView.loadFileURL(fileURL, allowingReadAccessTo: bookRoot)
            return
        }
        if let pageTurn, context.coordinator.lastTurnID != pageTurn.id {
            context.coordinator.performPageTurn(on: webView, request: pageTurn)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onProgress: onProgress, onPages: onPages,
                    onSelection: onSelection)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onReady: (WKWebView) -> Void
        let onProgress: (Double) -> Void
        let onPages: (Int, Int) -> Void
        let onSelection: (EbookSelection) -> Void
        var loadedURL: URL?
        var lastTurnID: UUID?

        init(onReady: @escaping (WKWebView) -> Void,
             onProgress: @escaping (Double) -> Void,
             onPages: @escaping (Int, Int) -> Void,
             onSelection: @escaping (EbookSelection) -> Void) {
            self.onReady = onReady
            self.onProgress = onProgress
            self.onPages = onPages
            self.onSelection = onSelection
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onReady(webView)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "ebookProgress",
               let value = message.body as? NSNumber {
                onProgress(value.doubleValue)
            } else if message.name == "ebookPages",
                      let body = message.body as? [String: Any],
                      let count = body["count"] as? NSNumber,
                      let index = body["index"] as? NSNumber {
                onPages(count.intValue, index.intValue)
            } else if message.name == "ebookSelection",
                      let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      let x = body["x"] as? NSNumber,
                      let y = body["y"] as? NSNumber,
                      let w = body["w"] as? NSNumber,
                      let h = body["h"] as? NSNumber {
                let rect = CGRect(x: x.doubleValue, y: y.doubleValue,
                                  width: w.doubleValue, height: h.doubleValue)
                onSelection(EbookSelection(text: text, rect: rect))
            }
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

        /// 由分页 HTML 的 CSS 3D 完成翻页；这里只负责通知 JS 目标页。
        func performPageTurn(on webView: WKWebView, request: EbookPageTurnRequest) {
            lastTurnID = request.id
            webView.evaluateJavaScript(
                "window.__desireGoToPage && window.__desireGoToPage(\(request.target));",
                completionHandler: nil)
        }
    }
}

