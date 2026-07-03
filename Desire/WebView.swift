import Combine
import SwiftUI
import WebKit

@MainActor
class BrowserState: ObservableObject {
    let webView: WKWebView
    @Published var estimatedProgress: Double = 0
    @Published var pageTitle: String = "Desire"

    init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
    }
}

struct WebView: NSViewRepresentable {
    @ObservedObject var state: BrowserState
    @Binding var urlString: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = state.webView
        webView.navigationDelegate = context.coordinator
        context.coordinator.observe(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var lastNavigatedURL: String?
        private var observations: [NSKeyValueObservation] = []

        init(_ parent: WebView) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                    self?.parent.state.estimatedProgress = wv.estimatedProgress
                },
                webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                    if let title = wv.title, !title.isEmpty {
                        self?.parent.state.pageTitle = title
                    }
                },
            ]
        }

        func stopObserving() {
            observations.removeAll()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.state.estimatedProgress = 0
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.state.estimatedProgress = 1
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            if let url = webView.url {
                parent.urlString = url.absoluteString
                lastNavigatedURL = url.absoluteString
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
