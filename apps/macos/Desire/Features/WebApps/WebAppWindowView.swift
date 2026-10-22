import AppKit
import SwiftUI
import WebKit

/// App Mode 窗口（v0.8.0）：无地址栏/标签栏的最小 chrome，独立或共享登录。
struct WebAppWindowView: View {
    let appID: UUID
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var store = WebAppStore.shared
    @State private var title = ""
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var reloadToken = 0

    var body: some View {
        if let app = store.app(id: appID) {
            VStack(spacing: 0) {
                chrome(for: app)
                WebAppWebView(
                    app: app,
                    dataStore: store.dataStore(for: app),
                    title: $title,
                    canGoBack: $canGoBack,
                    canGoForward: $canGoForward,
                    reloadToken: reloadToken
                )
            }
            .frame(minWidth: 520, minHeight: 380)
            .navigationTitle(app.name)
            .onReceive(NotificationCenter.default.publisher(for: .closeWebApp)) { note in
                if let id = note.userInfo?["id"] as? String, id == appID.uuidString {
                    dismissWindow(id: "webapp", value: appID)
                }
            }
        } else {
            VStack(spacing: 10) {
                Text("Web App Not Found")
                    .font(.headline)
                Button("Close") { NSApp.keyWindow?.close() }
            }
            .frame(width: 320, height: 160)
        }
    }

    private func chrome(for app: WebApp) -> some View {
        HStack(spacing: 8) {
            Button { post(.goBack) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)
            Button { post(.goForward) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)
            Button { reloadToken += 1 } label: {
                Image(systemName: "arrow.clockwise")
            }
            Text(title.isEmpty ? app.name : title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let url = URL(string: app.startURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "safari")
            }
            .help("Open in default browser")
            Button { NSApp.keyWindow?.close() } label: {
                Image(systemName: "xmark")
            }
            .help("Close")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func post(_ action: WebAppNavigationAction) {
        NotificationCenter.default.post(name: .webAppNavigate, object: nil,
                                        userInfo: ["appID": appID, "action": action.rawValue])
    }
}

enum WebAppNavigationAction: String {
    case goBack
    case goForward
}

extension Notification.Name {
    static let webAppNavigate = Notification.Name("desire.webApp.navigate")
}

/// 最小 WKWebView 封装：App Mode 复用主浏览器的 UA / 内容过滤 / 内置脚本。
private struct WebAppWebView: NSViewRepresentable {
    let app: WebApp
    let dataStore: WKWebsiteDataStore
    @Binding var title: String
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    let reloadToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        AppState.live?.contentBlocker.apply(to: config)
        for script in UserScriptLoader.builtinScripts() {
            config.userContentController.addUserScript(script)
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = BrowserState._desktopSafariUA
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let url = URL(string: app.startURL) {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.webView = webView
        context.coordinator.observeNavigation(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            if webView.url != nil { webView.reload() }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebAppWebView
        weak var webView: WKWebView?
        var lastReloadToken = 0
        private var observations: [NSKeyValueObservation] = []
        private var navObserver: NSObjectProtocol?

        init(_ parent: WebAppWebView) {
            self.parent = parent
            super.init()
            navObserver = NotificationCenter.default.addObserver(
                forName: .webAppNavigate, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let appID = note.userInfo?["appID"] as? UUID,
                      appID == self.parent.app.id,
                      let raw = note.userInfo?["action"] as? String,
                      let action = WebAppNavigationAction(rawValue: raw),
                      let webView = self.webView else { return }
                switch action {
                case .goBack: if webView.canGoBack { webView.goBack() }
                case .goForward: if webView.canGoForward { webView.goForward() }
                }
            }
        }

        func observeNavigation(_ webView: WKWebView) {
            observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                let value = wv.canGoBack
                Task { @MainActor [weak self] in self?.parent.canGoBack = value }
            })
            observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                let value = wv.canGoForward
                Task { @MainActor [weak self] in self?.parent.canGoForward = value }
            })
            observations.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                let value = wv.title
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.parent.title = value ?? self.parent.app.name
                }
            })
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.title = webView.title ?? parent.app.name
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        /// App Mode 里 target=_blank 默认留在同一窗口（独立应用不需要再开
        /// 浏览器标签；OAuth 需要真弹窗的站点可先用主浏览器登录后共享会话）。
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        deinit {
            observations.forEach { $0.invalidate() }
            if let navObserver { NotificationCenter.default.removeObserver(navObserver) }
        }
    }
}
