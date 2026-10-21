import SwiftUI
import WebKit

struct ReaderView: View {
    let title: String
    let contentHTML: String
    /// 提取时的页面 URL（v0.7.28）：相对图片/链接的解析基准。
    let baseURL: URL?
    let isLoading: Bool
    let onClose: () -> Void
    /// 阅读视图里点到链接：关闭阅读模式并在原标签打开（v0.7.28）。
    let onOpenURL: (URL) -> Void

    /// 站点级偏好（v0.7.29）：打开时套用该 host 的覆盖（没有则跟随全局）。
    init(title: String, contentHTML: String, baseURL: URL?, isLoading: Bool,
         onClose: @escaping () -> Void, onOpenURL: @escaping (URL) -> Void) {
        self.title = title
        self.contentHTML = contentHTML
        self.baseURL = baseURL
        self.isLoading = isLoading
        self.onClose = onClose
        self.onOpenURL = onOpenURL
        _settings = State(initialValue: ReaderSettings.load(host: baseURL?.host))
    }

    @State private var settings: ReaderSettings
    @ObservedObject private var speech = ReaderSpeechService.shared
    /// 高亮（v0.7.29）：控制器桥接阅读 webview，store 负责持久化。
    @StateObject private var readerController = ReaderController()
    @ObservedObject private var highlightStore = ReaderHighlightStore.shared
    @State private var showHighlights = false
    /// 朗读源剥离 HTML 后的纯文本（body 出现一次后缓存，避免每帧重剥）。
    @State private var plainText: String = ""
    /// "保存离线"的瞬时反馈（v0.7.28）。
    @State private var offlineNote: String?

    private var pageURLString: String { baseURL?.absoluteString ?? "" }

    /// 只在高亮集合/颜色变化时重绘标记（备注输入不应每次重包 DOM）。
    private var highlightRenderKey: String {
        highlightStore.list(for: pageURLString)
            .map { "\($0.id.uuidString)-\($0.color.rawValue)" }
            .joined(separator: "|")
    }

    private var speechText: String { plainText.isEmpty ? Self.stripHTML(contentHTML) : plainText }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                Spacer()

                // 字号步进
                HStack(spacing: 4) {
                    Button { stepFont(-1) } label: {
                        Text("A").font(.system(size: 11))
                    }
                    Button { stepFont(1) } label: {
                        Text("A").font(.system(size: 15, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                // TTS 朗读（0.6.5）：端上合成，暂停/继续/停止三态。
                HStack(spacing: 4) {
                    if speech.isSpeaking {
                        Button {
                            speech.togglePause()
                        } label: {
                            Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(speech.isPaused ? "Resume Reading" : "Pause Reading")

                        Button {
                            speech.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Stop Reading")
                    } else {
                        Button {
                            speech.speak(speechText)
                        } label: {
                            Image(systemName: "speaker.wave.3")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Read Aloud")
                    }
                }
                .foregroundStyle(speech.isSpeaking ? Color.accentColor : .secondary)

                // 行距切换（紧凑/标准/宽松）
                if let offlineNote {
                    Text(offlineNote)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Button { saveOffline() } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save offline copy")
                Button { addHighlight() } label: {
                    Image(systemName: "highlighter")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Highlight selection")
                Button { showHighlights = true } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Highlights")
                Menu {
                    ForEach([1.4, 1.7, 2.0], id: \.self) { spacing in
                        Button(spacing == 1.4 ? "Tight" : spacing == 1.7 ? "Normal" : "Loose") {
                            settings.lineSpacing = spacing
                            settings.save()
                        }
                    }
                } label: {
                    Image(systemName: "text.line.height")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)

                // 主题
                Menu {
                    ForEach(ReaderSettings.Theme.allCases) { theme in
                        Button(theme.rawValue.capitalized) {
                            settings.theme = theme
                            settings.save()
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)

                // 站点级偏好（v0.7.29）：把当前字号/行距/主题钉到本站。
                Menu {
                    Button(String(localized: "Remember for this site")) {
                        settings.saveForSite(baseURL?.host)
                    }
                    Button(String(localized: "Use global settings")) {
                        ReaderSettings.clearSiteOverride(baseURL?.host)
                        settings = ReaderSettings.load()
                    }
                } label: {
                    Image(systemName: "pin")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .help("Use these settings for this site only")

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(height: 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Extracting content…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No readable content found")
                        .font(.headline)
                    Text("This page may not have a readable article format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ReaderWebView(html: wrappedHTML,
                              baseURL: baseURL,
                              urlKey: baseURL?.absoluteString ?? "",
                              controller: readerController,
                              onOpenURL: onOpenURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(settingsIdentity) // 设置变化重载（HTML 模板内联样式）
            }
        }
        // 离开阅读模式即停朗读（切标签/关面板不残留语音）。
        .onDisappear { speech.stop() }
        .sheet(isPresented: $showHighlights) {
            ReaderHighlightsSheet(url: pageURLString,
                                  store: highlightStore,
                                  onJump: { id in
                                      Task { await readerController.scrollTo(id) }
                                  },
                                  onClose: { showHighlights = false })
        }
        .onChange(of: highlightRenderKey) { _, _ in
            Task { await readerController.apply(highlightStore.list(for: pageURLString)) }
        }
    }

    private var settingsIdentity: String {
        "\(settings.fontSize)-\(settings.theme.rawValue)-\(settings.lineSpacing)"
    }

    private func stepFont(_ delta: Int) {
        settings.fontSize = max(14, min(26, settings.fontSize + delta))
        settings.save()
    }

    /// 高亮当前选区（v0.7.29）：值/锚点存本地，阅读视图立即重绘。
    private func addHighlight() {
        guard !pageURLString.isEmpty else { return }
        Task { @MainActor in
            guard let anchor = await readerController.selectedAnchor() else {
                offlineNote = String(localized: "Select text first")
                return
            }
            _ = highlightStore.add(url: pageURLString, quote: anchor.quote,
                                   prefix: anchor.prefix, suffix: anchor.suffix)
            await readerController.apply(highlightStore.list(for: pageURLString))
            offlineNote = String(localized: "Highlighted")
            try? await Task.sleep(for: .seconds(1.5))
            offlineNote = nil
        }
    }

    /// 保存离线（v0.7.28）：把干净的阅读正文挂到阅读列表条目的离线缓存上
    /// （没有条目就先加一条）——列表右键"Open Offline Copy"即可离线打开。
    private func saveOffline() {
        guard let baseURL,
              !contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            offlineNote = String(localized: "Nothing to save")
            return
        }
        guard let store = AppState.live?.readingListStore else {
            offlineNote = String(localized: "Reading list unavailable")
            return
        }
        let urlString = baseURL.absoluteString
        if store.items.first(where: { $0.url == urlString }) == nil {
            store.add(title: title.isEmpty ? (baseURL.host ?? urlString) : title,
                      url: urlString)
        }
        guard let item = store.items.first(where: { $0.url == urlString }),
              let outcome = ReadingListCache.saveReaderHTML(wrappedHTML, itemID: item.id) else {
            offlineNote = String(localized: "Could not save offline")
            return
        }
        store.setCache(item.id, fileURL: outcome.fileURL)
        offlineNote = String(localized: "Saved offline")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            offlineNote = nil
        }
    }

    private var wrappedHTML: String {
        let themeCSS: String
        switch settings.theme {
        case .auto:
            themeCSS = """
            body { color: #1a1a1a; background: transparent; }
            a { color: #007aff; }
            pre, code { background: #f5f5f5; }
            blockquote { color: #555; }
            @media (prefers-color-scheme: dark) {
                body { color: #e0e0e0; background: #1c1c1e; }
                a { color: #5ac8fa; }
                pre, code { background: #2c2c2e; }
                blockquote { color: #aaa; }
            }
            """
        case .light:
            themeCSS = "body { color: #1a1a1a; background: #ffffff; } a { color: #007aff; } pre, code { background: #f5f5f5; } blockquote { color: #555; }"
        case .sepia:
            themeCSS = "body { color: #4a4234; background: #f4ecd8; } a { color: #9a6b00; } pre, code { background: #e8dcc0; } blockquote { color: #7a6a52; }"
        case .dark:
            themeCSS = "body { color: #e0e0e0; background: #1c1c1e; } a { color: #5ac8fa; } pre, code { background: #2c2c2e; } blockquote { color: #aaa; }"
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body {
                font-family: -apple-system, Georgia, serif;
                font-size: \(settings.fontSize)px;
                line-height: \(settings.lineSpacing);
                padding: 20px 30px;
                max-width: 680px;
                margin: 0 auto;
            }
            h1 {
                font-family: -apple-system;
                font-size: \(settings.fontSize + 10)px;
                font-weight: 700;
                line-height: 1.2;
                margin-bottom: 0.5em;
            }
            p { margin: 1em 0; }
            img { max-width: 100%; height: auto; border-radius: 4px; }
            pre { overflow-x: auto; padding: 12px; border-radius: 6px; font-size: \(settings.fontSize - 4)px; }
            code { font-size: \(settings.fontSize - 4)px; padding: 2px 6px; border-radius: 3px; }
            blockquote { border-left: 3px solid #007aff; margin: 1em 0; padding: 0.5em 1em; }
            \(themeCSS)
        </style>
        </head>
        <body>
        <h1>\(title)</h1>
        \(contentHTML)
        </body>
        </html>
        """
    }
}

private struct ReaderWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    let urlKey: String
    let controller: ReaderController
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(urlKey: urlKey, controller: controller, onOpenURL: onOpenURL)
    }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        controller.attach(wv)
        // baseURL 让相对图片/链接可解析（v0.7.28：此前是 nil，图全裂）。
        wv.loadHTMLString(html, baseURL: baseURL)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 设置变化经 .id 重挂载，无需 update 处理。
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.persistScroll(of: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let urlKey: String
        let controller: ReaderController
        let onOpenURL: (URL) -> Void

        init(urlKey: String, controller: ReaderController,
             onOpenURL: @escaping (URL) -> Void) {
            self.urlKey = urlKey
            self.controller = controller
            self.onOpenURL = onOpenURL
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 阅读视图里的链接不再在阅读视图内漫游：回到原标签打开。
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                decisionHandler(.cancel)
                onOpenURL(url)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !urlKey.isEmpty,
               let y = ReaderScrollMemory.restore(for: urlKey), y > 0 {
                webView.evaluateJavaScript("window.scrollTo(0, \(y));", completionHandler: nil)
            }
            // 重开/换字号后重绘高亮（v0.7.29）。
            Task { @MainActor [controller, urlKey] in
                await controller.apply(ReaderHighlightStore.shared.list(for: urlKey))
            }
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { onOpenURL(url) }
            return nil
        }

        func persistScroll(of webView: WKWebView) {
            let key = urlKey
            guard !key.isEmpty else { return }
            webView.evaluateJavaScript("window.scrollY") { value, _ in
                if let y = value as? Double, y > 0 {
                    ReaderScrollMemory.save(y, for: key)
                }
            }
        }
    }
}

/// 阅读视图的滚动位置记忆（v0.7.28）：按页面 URL 存最近位置——字号/主题切换会
/// 重建 webview，重新打开阅读模式也不该回到顶部。
enum ReaderScrollMemory {
    private static let key = "reader.scrollPositions"
    private static let cap = 200

    static func restore(for urlKey: String) -> Double? {
        guard !urlKey.isEmpty else { return nil }
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return map[urlKey]
    }

    static func save(_ y: Double, for urlKey: String) {
        guard !urlKey.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        map[urlKey] = y
        if map.count > cap {
            for stale in map.keys.prefix(map.count - cap) { map.removeValue(forKey: stale) }
        }
        UserDefaults.standard.set(map, forKey: key)
    }
}

#Preview {
    ReaderView(title: "示例文章标题",
               contentHTML: "<p>这是阅读模式的内容预览。</p><p>第二段内容。</p>",
               baseURL: URL(string: "https://example.com/article"),
               isLoading: false,
               onClose: {},
               onOpenURL: { _ in })
        .frame(width: 600, height: 400)
}
