import Combine
import Security
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserWKWebView: WKWebView {
    var onOpenLinkInNewTab: ((URL) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        let point = convert(event.locationInWindow, from: nil)
        let x = Int(point.x), y = Int(point.y)
        let js = """
        (function() {
            var el = document.elementFromPoint(\(x), \(y));
            var img = el.closest('img');
            var link = el.closest('a');
            var bg = window.getComputedStyle(el).backgroundImage;
            return JSON.stringify({
                imageUrl: img ? img.src : null,
                linkUrl: link ? link.href : null,
                bgImageUrl: bg && bg.startsWith('url(') ? bg.slice(4, -1).replace(/['"]/g, '') : null
            });
        })()
        """
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }

            let imageURL = info["imageUrl"].flatMap(URL.init)
            let linkURL = info["linkUrl"].flatMap(URL.init)
            let bgImageURL = info["bgImageUrl"].flatMap(URL.init)

            if let url = imageURL ?? bgImageURL {
                let save = NSMenuItem(title: "保存图片", action: #selector(self.saveImage), keyEquivalent: "")
                save.target = self
                save.representedObject = url
                menu.addItem(save)

                let copyURL = NSMenuItem(title: "复制图片地址", action: #selector(self.copyImageURL), keyEquivalent: "")
                copyURL.target = self
                copyURL.representedObject = url
                menu.addItem(copyURL)

                let copyImage = NSMenuItem(title: "复制图片", action: #selector(self.copyImage), keyEquivalent: "")
                copyImage.target = self
                copyImage.representedObject = url
                menu.addItem(copyImage)
            }

            if let url = linkURL {
                if imageURL != nil || bgImageURL != nil { menu.addItem(.separator()) }
                let open = NSMenuItem(title: "在新标签页中打开链接", action: #selector(self.openLinkInNewTab), keyEquivalent: "")
                open.target = self
                open.representedObject = url
                menu.addItem(open)

                let copyLink = NSMenuItem(title: "复制链接地址", action: #selector(self.copyLinkURL), keyEquivalent: "")
                copyLink.target = self
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
        }
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenLinkInNewTab?(url)
    }

    @objc private func saveImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let task = URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data, error == nil else { return }
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = url.lastPathComponent
                panel.allowedContentTypes = [.image]
                guard panel.runModal() == .OK, let targetURL = panel.url else { return }
                try? data.write(to: targetURL)
            }
        }
        task.resume()
    }

    @objc private func copyImageURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func copyImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
        task.resume()
    }

    @objc private func copyLinkURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func requestInspector() {
        guard let inspector = value(forKey: "_inspector") as? NSObject else { return }
        inspector.perform(Selector(("show")))
    }
}

@MainActor
class BrowserState: ObservableObject {
    let webView: BrowserWKWebView
    @Published var estimatedProgress: Double = 0
    @Published var pageTitle: String = "Desire"
    @Published var isSecure: Bool = false
    @Published var lastError: String?
    @Published var pageZoom: Double = 1.0
    @Published var serverTrust: SecTrust?
    @Published var isPlayingAudio: Bool = false
    @Published var isMuted: Bool = false

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

        let audioJS = """
        (function() {
            function checkAudio() {
            var playing = false;
            document.querySelectorAll('audio, video').forEach(function(el) {
                if (!el.paused && el.volume > 0) {
                        playing = true;
                    }
                });
                window.webkit.messageHandlers.audioState.postMessage(playing);
            }
            document.addEventListener('play', checkAudio, true);
            document.addEventListener('pause', checkAudio, true);
            document.addEventListener('volumechange', checkAudio, true);
            new MutationObserver(function() {
                if (document.querySelectorAll('audio, video').length) checkAudio();
            }).observe(document.body, { childList: true, subtree: true });
            setTimeout(checkAudio, 500);
        })();
        """
        let audioScript = WKUserScript(source: audioJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        config.userContentController.addUserScript(audioScript)

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
        webView.uiDelegate = context.coordinator
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

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        var parent: WebView
        var lastNavigatedURL: String?
        private var observations: [NSKeyValueObservation] = []
        private var activeDownloads: [ObjectIdentifier: UUID] = [:]

        init(_ parent: WebView) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            webView.configuration.userContentController.add(self, name: "audioState")

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
            let wv = parent.state.webView
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "audioState")
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.onOpenLinkInNewTab = nil
            wv.stopLoading()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "audioState", let playing = message.body as? Bool {
                parent.state.isPlayingAudio = playing
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.state.estimatedProgress = 0
            parent.state.lastError = nil
            parent.state.serverTrust = nil
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                parent.state.serverTrust = challenge.protectionSpace.serverTrust
            }
            completionHandler(.performDefaultHandling, nil)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.state.isSecure = webView.url?.scheme == "https"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.state.estimatedProgress = 1
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            parent.state.lastError = nil
            if let url = webView.url {
                parent.urlString = url.absoluteString
                lastNavigatedURL = url.absoluteString
                parent.state.isSecure = url.scheme == "https"
                parent.onPageFinished?(url, parent.state.pageTitle)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.state.lastError = error.localizedDescription
        }

        // 处理新窗口/弹窗（Google 登录 OAuth 需要）
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if let scheme = url.scheme?.lowercased(), Self.externalSchemes.contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame == nil {
                // 弹窗式导航（OAuth 等），改为当前窗口加载
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }

            // Cmd+点击链接 — 后台打开新标签
            if navigationAction.modifierFlags.contains(.command) {
                parent.onOpenLinkInNewTab?(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private static let externalSchemes: Set<String> = [
            "mailto", "tel", "facetime", "sms",
            "maps", "itunes", "music", "podcasts",
            "appstore", "macappstore"
        ]

        // 无法展示的 MIME 类型（.pkg/.dmg/.zip 等直接文件链接）转为下载，
        // 否则 WebKit 会尝试渲染并失败（code 102 "frame load interrupted"）
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.state.lastError = error.localizedDescription
        }

        // MARK: - WKUIDelegate - 权限请求

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let deviceName: String = switch type {
            case .camera: "摄像头"
            case .microphone: "麦克风"
            case .cameraAndMicrophone: "摄像头和麦克风"
            @unknown default: "媒体设备"
            }
            let host = origin.host
            let alert = NSAlert()
            alert.messageText = "\(host) 想要访问你的\(deviceName)"
            alert.informativeText = "允许此网站访问\(deviceName)吗？"
            alert.addButton(withTitle: "允许")
            alert.addButton(withTitle: "拒绝")
            let response = alert.runModal()
            decisionHandler(response == .alertFirstButtonReturn ? .grant : .deny)
        }

        func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let host = origin.host
            let alert = NSAlert()
            alert.messageText = "\(host) 想要获取你的位置信息"
            alert.informativeText = "允许此网站获取你的位置吗？"
            alert.addButton(withTitle: "允许")
            alert.addButton(withTitle: "拒绝")
            let response = alert.runModal()
            decisionHandler(response == .alertFirstButtonReturn ? .grant : .deny)
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canCreateDirectories = false
            guard panel.runModal() == .OK else { completionHandler(nil); return }
            completionHandler(panel.urls)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = message
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = message
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = prompt
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return textField.stringValue
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            let filename = download.originalRequest?.url?.lastPathComponent ?? "下载项"
            let id = parent.downloadStore.add(item: DownloadItem(
                filename: filename,
                fileURL: nil,
                totalBytes: 0,
                downloadedBytes: 0,
                state: .inProgress,
                error: nil,
                cancel: { [weak download] in download?.cancel() }
            ))
            activeDownloads[ObjectIdentifier(download)] = id
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
