import Combine
import SwiftUI
import WebKit

@MainActor
class BrowserWKWebView: WKWebView {
    var onOpenLinkInNewTab: ((URL) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        let point = convert(event.locationInWindow, from: nil)
        evaluateJavaScript("document.elementFromPoint(\(Int(point.x)), \(Int(point.y))).closest('a')?.href") { [weak self] result, _ in
            guard let self, let urlString = result as? String, let url = URL(string: urlString) else { return }

            let item = NSMenuItem(title: "在新标签页中打开", action: #selector(self.openLinkInNewTab), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(.separator())
            menu.addItem(item)
        }
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenLinkInNewTab?(url)
    }
}

@MainActor
class BrowserState: ObservableObject {
    let webView: BrowserWKWebView
    @Published var estimatedProgress: Double = 0
    @Published var pageTitle: String = "Desire"
    @Published var isSecure: Bool = false

    init(incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlocker? = nil) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.javaScriptEnabled = javaScriptEnabled
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if incognito {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        config.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        contentBlocker?.apply(to: config)

        webView = BrowserWKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
    }
}

struct WebView: NSViewRepresentable {
    @ObservedObject var state: BrowserState
    @ObservedObject var downloadStore: DownloadStore
    @Binding var urlString: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    var onOpenLinkInNewTab: ((URL) -> Void)?
    var onPageFinished: ((URL, String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> BrowserWKWebView {
        let webView = state.webView
        webView.navigationDelegate = context.coordinator
        webView.onOpenLinkInNewTab = { url in
            context.coordinator.parent.onOpenLinkInNewTab?(url)
        }
        context.coordinator.observe(webView)
        return webView
    }

    func updateNSView(_ nsView: BrowserWKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: BrowserWKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        var parent: WebView
        var lastNavigatedURL: String?
        private var observations: [NSKeyValueObservation] = []
        private var activeDownloads: [ObjectIdentifier: UUID] = [:]

        init(_ parent: WebView) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                    self?.parent.state.estimatedProgress = wv.estimatedProgress
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
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

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.state.isSecure = webView.url?.scheme == "https"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.state.estimatedProgress = 1
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            if let url = webView.url {
                parent.urlString = url.absoluteString
                lastNavigatedURL = url.absoluteString
                parent.state.isSecure = url.scheme == "https"
                parent.onPageFinished?(url, parent.state.pageTitle)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        // 处理新窗口/弹窗（Google 登录 OAuth 需要）
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame == nil,
               let url = navigationAction.request.url {
                // 弹窗式导航（OAuth 等），改为当前窗口加载
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            let id = UUID()
            activeDownloads[ObjectIdentifier(download)] = id
            let filename = download.originalRequest?.url?.lastPathComponent ?? "下载项"
            parent.downloadStore.add(item: DownloadItem(
                filename: filename,
                fileURL: nil,
                totalBytes: 0,
                downloadedBytes: 0,
                state: .inProgress,
                error: nil
            ))
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let destination = parent.downloadStore.uniqueURL(for: suggestedFilename)
            if let id = activeDownloads[ObjectIdentifier(download)] {
                parent.downloadStore.setDestination(
                    id: id,
                    filename: suggestedFilename,
                    fileURL: destination,
                    totalBytes: response.expectedContentLength
                )
            }
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            if let id = activeDownloads[ObjectIdentifier(download)] {
                parent.downloadStore.complete(id: id)
            }
            activeDownloads[ObjectIdentifier(download)] = nil
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let id = activeDownloads[ObjectIdentifier(download)] {
                parent.downloadStore.fail(id: id, message: error.localizedDescription)
            }
            activeDownloads[ObjectIdentifier(download)] = nil
        }
    }
}
