import AppKit
import os
import Combine
import Security
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A non-empty text selection reported by `selection-ai.js`, with the
/// selection rect in viewport CSS pixels (for positioning the AI bar).
struct SelectionAIInfo: Equatable {
    let text: String
    let viewportX: CGFloat
    let viewportY: CGFloat
}

/// A pending `beforeunload` confirmation: the page has registered a
/// beforeunload handler and is navigating away, and the user (or the
/// automation bridge) must choose to leave (discard form data) or stay.
/// `respond` is single-fire — the sheet button and the bridge may race.
@MainActor
final class PendingBeforeUnload {
    let message: String
    /// Dismisses the on-screen sheet programmatically (set by the
    /// coordinator that presented it); a no-op when the user already clicked.
    var programmaticDismiss: (() -> Void)?

    private let completion: (Bool) -> Void
    private var resolved = false

    init(message: String, completion: @escaping (Bool) -> Void) {
        self.message = message
        self.completion = completion
    }

    func respond(leave: Bool) {
        guard !resolved else { return }
        resolved = true
        programmaticDismiss?()
        completion(leave)
    }
}

/// 高危下载确认（0.2.15 加固）：安装器/可执行脚本/磁盘镜像的下载在
/// navigationResponse 决策点被取消，改为挂起这条非阻塞确认（模态
/// NSAlert 会冻结自动化桥——密码保存条的同款教训）。确认后 URL 进
/// `dangerousDownloadAllowedURLs` 白名单并重载放行一次。
@MainActor
final class PendingDangerousDownload {
    let url: URL
    let filename: String
    var programmaticDismiss: (() -> Void)?

    private let completion: (Bool) -> Void
    private var resolved = false

    init(url: URL, filename: String, completion: @escaping (Bool) -> Void) {
        self.url = url
        self.filename = filename
        self.completion = completion
    }

    func respond(_ allow: Bool) {
        guard !resolved else { return }
        resolved = true
        programmaticDismiss?()
        completion(allow)
    }
}

@MainActor
class BrowserState: ObservableObject {
    let webView: BrowserWKWebView
    /// This page runs in an incognito tab (non-persistent data store).
    /// Downloads created here are tagged private so they never reach the
    /// shared download history on disk.
    let isIncognito: Bool
    /// Current user text selection (nil when collapsed/empty) — drives the
    /// selection AI bar in `SelectedTabContent`.
    @Published var selectionAI: SelectionAIInfo?
    @Published var estimatedProgress: Double = 0
    @Published var pageTitle: String = "Desire"
    @Published var isSecure: Bool = false
    /// 混合内容（0.2.15 加固）：https 页面上加载的 http 子资源计数。
    /// scripts 单列——被动脚本才是真正的风险面。
    @Published var mixedContentTotal: Int = 0
    @Published var mixedContentScripts: Int = 0
    /// 高危下载确认（非阻塞条 + 桥可代答）。
    @Published var pendingDangerousDownload: PendingDangerousDownload?
    /// 用户确认"仍然下载"的 URL——重载放行一次后移除。
    var dangerousDownloadAllowedURLs: Set<String> = []
    /// WebExtension：该页是否有 tabs.* 事件监听（决定事件 hub 是否向此
    /// 页 evaluate）。
    var hasExtensionTabListeners = false
    /// OTP 提示条（0.3.6）：页面出现验证码输入框时非 nil（值为字段名），
    /// 导航开始时清空。
    @Published var pendingOTPHint: String?
    @Published var lastError: Error?
    /// Default comes from 设置 ▸ Appearance ▸ Page Zoom (UserDefaults 直读,
    /// 对新建标签生效；已存在的标签不受影响)。
    @Published var pageZoom: Double = UserDefaults.standard.object(forKey: "defaultPageZoom") as? Double ?? 1.0
    @Published var serverTrust: SecTrust?
    @Published var isPlayingAudio: Bool = false
    @Published var isMuted: Bool = false
    @Published var isReadingMode = false
    @Published var isReaderLoading = false
    @Published var readerTitle = ""
    @Published var readerContent = ""
    @Published var hoveredLinkURL: String?
    @Published var isPickingElement = false
    /// A beforeunload confirmation awaiting a decision (also resolvable via
    /// the automation bridge). nil when nothing is pending.
    @Published var pendingBeforeUnload: PendingBeforeUnload?
    /// Media resources sniffed on this page (network + DOM scan). Cleared
    /// when a navigation commits to a new page. Consumed by the AI
    /// `listPageVideos` tool; capped, session-scoped, never persisted.
    @Published var detectedMedia: [MediaResource] = []
    var onAIElementPicked: ((String, String) -> Void)?
    let videoAdBlocker: VideoAdBlocker?

    init(incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlockerStore? = nil, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction, containerDataStore: WKWebsiteDataStore? = nil) {
        self.isIncognito = incognito
        self.videoAdBlocker = videoAdBlocker
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webpagePrefs = WKWebpagePreferences()
        webpagePrefs.allowsContentJavaScript = javaScriptEnabled
        config.defaultWebpagePreferences = webpagePrefs
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Performance optimizations
        config.preferences.setValue(true, forKey: "DOMPasteAllowed")
        config.preferences.setValue(false, forKey: "suppressesIncrementalRendering") // Render progressively

        switch autoPlayPolicy {
        case .allowAll:
            config.mediaTypesRequiringUserActionForPlayback = []
        case .requireUserAction:
            config.mediaTypesRequiringUserActionForPlayback = [.video, .audio]
        case .never:
            config.mediaTypesRequiringUserActionForPlayback = [.video, .audio]
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
        }
        if incognito {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        } else if let containerDataStore {
            // Container tab: dedicated persistent data store — cookies,
            // sessions, and site storage are isolated per container.
            config.websiteDataStore = containerDataStore
        }
        // Privacy settings (cookie accept policy, WebRTC kill switch) ride
        // EVERY new webview configuration — this wiring was missing, so the
        // Settings pickers were dead controls.
        PrivacyModeStore.shared.applyPrivacySettingsStore(to: config)
        // Use a full, real-Safari User-Agent (see `_desktopSafariUA` for the
        // exact requirements). The base macOS WKWebView UA is just
        //   Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15
        //   (KHTML, like Gecko)   <-- missing Version/ and Safari/ tokens
        // Cloudflare and other WAFs treat that as an unknown client, which is
        // why "由 Cloudflare 提供的性能和安全服务" verification challenges fire on
        // most sites. `applicationNameForUserAgent` is only the fallback for
        // the very first request (before the per-view `customUserAgent` below
        // takes over); it must stay free of extra tokens so the fallback is
        // also a complete, genuine-shaped Safari UA.
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // Explicitly enable HTML5 Fullscreen API for video sites (YouTube, etc.).
        // Defaults to true, but being explicit avoids edge cases where the
        // fullscreen transition silently no-ops inside SwiftUI-hosted WKWebView.
        config.preferences.isElementFullscreenEnabled = true
        config.applicationNameForUserAgent = "Version/26.5 Safari/605.1.15"
        contentBlocker?.apply(to: config)
        // Network interception rules (0.1.13): block/redirect applied to
        // every new webview; late rules distribute to registered views.
        InterceptStore.shared.apply(to: config.userContentController)
        // Community filter lists (EasyList) — process-wide singleton.
        FilterListStore.shared.apply(to: config)
        if let videoAdBlocker, videoAdBlocker.isEnabled {
            config.userContentController.addUserScript(videoAdBlocker.documentStartScript())
            config.userContentController.addUserScript(videoAdBlocker.documentEndScript())
        }

        // Desire's own always-on user scripts, centralized in
        // UserScriptLoader.builtinScripts() — the WebExtension registry
        // rebuilds builtins + extension scripts after enable/disable churn
        // (removeAllUserScripts is the only removal API available).
        for script in UserScriptLoader.builtinScripts() {
            config.userContentController.addUserScript(script)
        }
        // WebExtension API runtime — isolated world (page JS can't see it).
        if let extScript = UserScriptLoader.extensionAPIScript() {
            config.userContentController.addUserScript(extScript)
        }

        webView = BrowserWKWebView(frame: .zero, configuration: config)
        // Cookie-policy changes must reach this OPEN page too.
        PrivacyModeStore.shared.registerWebView(webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        // drawsBackground 保持默认（不透明）：0.3.9 曾用 KVC 关掉它试图
        // 消 resize 过场闪（8a880f6），历轮实测均未通过——透明内容让
        // WebKit 无法只拉伸旧帧过渡 resize，每帧合成页面背景反而加剧
        // 闪烁。勿再关闭。
        // Set the full Safari 26.5 UA on the WKWebView instance itself.
        // (See `applyDesktopSafariUA(to:)` for why this is on the view, not
        // the configuration.)
        Self.applyDesktopSafariUA(to: webView)
    }

    /// Records a sniffed media resource: dedupe by URL (refresh in place),
    /// newest first, hard cap so pathological pages can't grow it forever.
    func record(detectedMedia resource: MediaResource) {
        if let idx = detectedMedia.firstIndex(where: { $0.url == resource.url }) {
            detectedMedia[idx] = resource
        } else {
            detectedMedia.insert(resource, at: 0)
            if detectedMedia.count > 100 {
                detectedMedia.removeLast(detectedMedia.count - 100)
            }
        }
    }

    /// Applies the full desktop Safari User-Agent to a WKWebView instance.
    ///
    /// The macOS quirk that matters: `WKWebViewConfiguration` has no
    /// `customUserAgent` (nor a KVC key for one) on any platform — the
    /// configuration only offers `applicationNameForUserAgent`, which merely
    /// appends a token to the short default UA. The view-level
    /// `WKWebView.customUserAgent` property (public since macOS 10.11) is the
    /// only way to install a complete UA, so it is set right after the view
    /// is constructed, and again in `didStartProvisionalNavigation` (WebKit
    /// bug 313542: the first `load(_:)` request can still go out with the
    /// configuration fallback).
    ///
    /// This is the **single source of truth** for the desktop UA — every
    /// BrowserState instance starts with the same string so the back-forward
    /// cache and WAFs see a consistent identity.
    static func applyDesktopSafariUA(to webView: WKWebView) {
        webView.customUserAgent = _desktopSafariUA
    }

    /// Cached desktop User-Agent for Desire.
    ///
    /// Byte-identical to what Safari 26.5 on macOS 26.5 (Tahoe) emits. Every
    /// token matters, and nothing may be appended:
    ///
    /// - `Mac OS X 10_15_7` is the legacy OS-string WebKit still emits;
    ///   changing it to a real `26_5_2` trips Cloudflare's "unknown browser"
    ///   rule.
    /// - The string must **end** with `Safari/605.1.15`. WAFs validate
    ///   Safari-claiming UAs against that exact shape, so a trailing product
    ///   token (`Desire/0.1` — RFC 9110-legal as it is) marks the client as
    ///   non-genuine and brings back the Cloudflare challenge / block page on
    ///   plain page loads. Chrome and Firefox can afford extra tokens because
    ///   they sit on WAFs' known-browser lists; a WebKit browser claiming
    ///   Safari cannot. Desire's identity travels in other channels (bundle
    ///   ID, About panel), not in the UA.
    static let _desktopSafariUA: String =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/26.5 Safari/605.1.15"
}

struct WebView: NSViewRepresentable {
    @ObservedObject var state: BrowserState
    @ObservedObject var downloadStore: DownloadStore
    @ObservedObject var passwordStore: PasswordStore
    @ObservedObject var formAutofillStore: FormAutofillStore
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var siteSettingsStore: SiteSettingsStore
    /// Write-only reference (used in the `devConsole` message handler to push
    /// console messages into the store). Not `@ObservedObject`: WebView never
    /// renders from this store, so observing it would invalidate the
    /// representable on every console line from every frame — pure overhead.
    let devToolsStore: DevToolsStore
    @Binding var urlString: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    var httpsUpgradeEnabled: Bool = true
    /// YouTube 赞助商片段跳过开关（didFinish 注入 sponsorblock.js）。
    var sponsorBlockEnabled: Bool = false
    /// 启用的 SponsorBlock 类别（随开关注入页面）。
    var sponsorBlockCategories: [String] = []
    var extensionManager: SafariExtensionStore?
    var onOpenLinkInNewTab: ((URL) -> Void)?
    var onSearchText: ((String) -> Void)?
    var onPageFinished: ((URL, String) -> Void)?
    var onElementPicked: ((String, String?) -> Void)?
    /// Forwarded from the `videoAdBlocked` WKScriptMessage handler.
    /// Parameters: (blockedCount, siteKey, actionKey). `siteKey` is one of
    /// "youtube" / "bilibili" / "tencent" / ... `actionKey` is optional
    /// ("skip" / "seek") — when set the count is already 1.
    var onVideoAdBlocked: ((Int, String?, String?) -> Void)?
    var onInspectedElement: ((InspectedElement) -> Void)?
    /// WebExtension API（0.2.13）：tabs.* 的宿主窗口通道。
    var onQueryTabs: (() -> [[String: Any]])?
    var onCreateTab: ((String) -> Void)?
    var onRemoveTab: ((String) -> Void)?
    @ObservedObject var elementBlockStore: ElementBlockStore

    /// 插件代码与 WebExtension API 运行在隔离 content world：页面 JS
    /// 看不到（也不能伪造）`browser.*`；DOM 共享，JS 全局隔离。
    static let extensionWorld = WKContentWorld.world(name: "desireExtensions")

    // Computed (not `static let`) so the file is read from the bundle lazily
    // on first use rather than at type-init time, before Bundle.main is ready.
    static var pickerJS: String { UserScriptLoader.load("element-picker") }

    static var exitPickerJS: String { UserScriptLoader.load("element-picker-exit") }

    /// JS that counts total matches of `query` in the page's text nodes.
    /// Used by the find-in-page UI. NOTE: TreeWalker.nextNode() only returns
    /// a boolean — the text lives on `walk.currentNode.nodeValue` (using
    /// `walk.nodeValue` throws, which used to zero the match count).
    static func findCountJS(query: String) -> String {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            var t = '\(escaped)';
            if (!t) return 0;
            var r = new RegExp(t.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'gi');
            var c = 0, walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
            while (walk.nextNode()) { c += (walk.currentNode.nodeValue.match(r) || []).length; }
            return c;
        })()
        """
    }

    /// 混合内容扫描（0.2.15）：https 页面上 http:// 子资源计数，按风险
    /// 分组——script/iframe/object 是主动加载（可执行/可嵌套），img/video
    /// 等是被动加载（主要涉及隐私与完整性）。
    static let mixedContentScanJS = """
    (function() {
        var active = document.querySelectorAll(
            'script[src^="http:"], iframe[src^="http:"], object[data^="http:"], embed[src^="http:"], link[rel="stylesheet"][href^="http:"]');
        var passive = document.querySelectorAll(
            'img[src^="http:"], source[src^="http:"], video[src^="http:"], audio[src^="http:"], link[href^="http:"]');
        return { total: active.length + passive.length, scripts: active.length };
    })()
    """

    /// JS that removes an element-block `<style>` rule by its ID, then
    /// restores the hidden elements. Used by the undo-toast overlay.
    static func undoBlockJS(ruleId: UUID, selector: String) -> String {
        let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            var s = document.getElementById('desire-blocked-\(ruleId.uuidString)');
            if (s) s.remove();
            document.querySelectorAll('\(escaped)').forEach(function(el) { el.style.display = ''; });
        })();
        """
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> BrowserWKWebView {
        let webView = state.webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.autoresizingMask = [.width, .height]
        webView.onOpenLinkInNewTab = { url in
            context.coordinator.parent.onOpenLinkInNewTab?(url)
        }
        webView.onSearchText = { text in
            context.coordinator.parent.onSearchText?(text)
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
        private var activeDownloads: [ObjectIdentifier: DownloadInfo] = [:]
        /// Partial destination file for in-flight RESUMED downloads, keyed by
        /// the new WKDownload object (cleared once decideDestination runs).
        private var resumeDestinations: [ObjectIdentifier: URL] = [:]
        private var pendingUpgrades: [String: URL] = [:]
        private var fallbackInProgress: Set<String> = []

        private struct DownloadInfo {
            let id: UUID
            let progressObservation: NSKeyValueObservation
        }

        private var loadTimeoutTask: Task<Void, Never>?

        private func disarmLoadTimeout() {
            loadTimeoutTask?.cancel()
            loadTimeoutTask = nil
        }

        init(_ parent: WebView) {
            self.parent = parent
        }

        /// Message handler names registered in `observe()` and removed in
        /// `stopObserving()`. Single source of truth: `addScriptMessageHandler`
        /// throws NSException on a duplicate name (crashing at layout time),
        /// so the two lists must never drift apart.
        private static let scriptMessageHandlers = [
            "audioState", "mediaFound", "passwordDetect", "passwordSave",
            "readerContent", "hoverLink", "middleClickLink", "selectionAI",
            "elementPicker", "videoAdBlocked", "devConsole",
        ]

        func observe(_ webView: WKWebView) {
            let contentController = webView.configuration.userContentController
            for name in Self.scriptMessageHandlers {
                // Remove-before-add makes re-hosting the same WKWebView
                // (fast tab switches recreate the representable) idempotent
                // instead of throwing on the duplicate name.
                contentController.removeScriptMessageHandler(forName: name)
                contentController.add(self, name: name)
            }
            // WebExtension RPC — isolated world handler (name space is per
            // world, so this doesn't collide with the page-world list).
            contentController.removeScriptMessageHandler(
                forName: "desireExt", contentWorld: WebView.extensionWorld)
            contentController.add(self, contentWorld: WebView.extensionWorld, name: "desireExt")
            // 快速切标签会重建 representable（stopObserving 摘过 hub 注册）——
            // 只要页面曾声明过监听，observe 时重新入册。
            if parent.state.hasExtensionTabListeners {
                ExtensionEventHub.shared.register(parent.state)
            }

            observations = [
                webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.state.estimatedProgress = wv.estimatedProgress
                    }
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                    if let title = wv.title, !title.isEmpty {
                        DispatchQueue.main.async { [weak self] in
                            self?.parent.state.pageTitle = title
                        }
                    }
                },
            ]
        }

        // 全屏走 WebKit 原生 element fullscreen(57df77e 启用 HTML5
        // Fullscreen API),窗口级同步方案(shim + KVO)经三轮实测均致
        // 黑屏/自动退屏,已整体移除——勿再引入。

        func stopObserving() {
            observations.removeAll()
            let wv = parent.state.webView
            for name in Self.scriptMessageHandlers {
                wv.configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
            wv.configuration.userContentController.removeScriptMessageHandler(
                forName: "desireExt", contentWorld: WebView.extensionWorld)
            ExtensionEventHub.shared.unregister(parent.state)
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.onOpenLinkInNewTab = nil
            wv.onOpenInContainer = nil
            wv.onSearchText = nil
            wv.stopLoading()
        }

        /// WebExtension RPC（0.2.13）：隔离世界里 `browser.*` 的宿主侧。
        /// 协议：{id, ns, fn, args[]} → `_resolve(id, ok, payloadJSON)`，
        /// payload 以 JSON 字面量内嵌（存储值已在 set 时校验可序列化）。
        private func handleExtensionMessage(_ body: Any) {
            guard let dict = body as? [String: Any],
                  let ns = dict["ns"] as? String,
                  let fn = dict["fn"] as? String else { return }
            let id = dict["id"] as? Int
            let args = dict["args"] as? [Any] ?? []
            // 插件身份（0.3.3）：有 → 存储按插件命名空间；无 → legacy。
            let extID = dict["ext"] as? String

            func reply(_ payload: Any?, error: String? = nil) {
                guard let id else { return }
                let json: String
                if let error {
                    let escaped = error
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    json = "\"\(escaped)\""
                } else if let payload,
                          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                          let str = String(data: data, encoding: .utf8) {
                    json = str
                } else {
                    json = "null"
                }
                let js = "window.__desireExt && window.__desireExt._resolve(\(id), \(error == nil), \(json))"
                parent.state.webView.evaluateJavaScript(
                    js, in: nil, in: WebView.extensionWorld, completionHandler: nil)
            }

            switch (ns, fn) {
            case ("storage", "get"):
                reply(WebExtensionStore.get(keys: args.first, ext: extID))
            case ("storage", "set"):
                guard let items = args.first as? [String: Any] else {
                    reply(nil, error: "storage.set requires an object")
                    return
                }
                WebExtensionStore.set(items: items, ext: extID)
                reply([:])
            case ("storage", "remove"):
                let keys = (args.first as? [Any])?.compactMap { $0 as? String } ?? []
                WebExtensionStore.remove(keys: keys, ext: extID)
                reply([:])
            case ("storage", "clear"):
                WebExtensionStore.clear(ext: extID)
                reply([:])
            case ("tabs", "query"):
                reply(parent.onQueryTabs?() ?? [])
            case ("tabs", "create"):
                if let url = (args.first as? [String: Any])?["url"] as? String, !url.isEmpty {
                    parent.onCreateTab?(url)
                    reply([:])
                } else {
                    reply(nil, error: "tabs.create requires {url}")
                }
            case ("tabs", "remove"):
                if let single = args.first as? String {
                    parent.onRemoveTab?(single)
                    reply([:])
                } else if let many = args.first as? [String] {
                    many.forEach { parent.onRemoveTab?($0) }
                    reply([:])
                } else {
                    reply(nil, error: "tabs.remove requires id(s)")
                }
            case ("notifications", "create"):
                WebExtensionStore.createNotification(args.first as? [String: Any] ?? [:]) { result in
                    reply(result)
                }
            case ("events", "addListener"):
                if let name = args.first as? String, name.hasPrefix("tabs.") {
                    parent.state.hasExtensionTabListeners = true
                    ExtensionEventHub.shared.register(parent.state)
                }
                reply([:])
            default:
                reply(nil, error: "unknown \(ns).\(fn)")
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "desireExt" {
                // Isolated-world WebExtension RPC (see extensionWorld).
                handleExtensionMessage(message.body)
            } else if message.name == "otpDetect", let dict = message.body as? [String: String] {
                parent.state.pendingOTPHint = dict["field"] ?? "verification code"
            } else if message.name == "audioState", let playing = message.body as? Bool {
                parent.state.isPlayingAudio = playing
            } else if message.name == "devConsole", let dict = message.body as? [String: Any],
                      let levelStr = dict["level"] as? String,
                      let msgText = dict["message"] as? String {
                let level = ConsoleMessage.Level(rawValue: levelStr) ?? .log
                let url = dict["url"] as? String
                let line = dict["line"] as? Int
                let column = dict["column"] as? Int
                parent.devToolsStore.addConsoleMessage(level: level, message: msgText, url: url, line: line, column: column)
            } else if message.name == "passwordDetect", let dict = message.body as? [String: String],
                       let usernameName = dict["username"],
                       let host = parent.state.webView.url?.host {
                let entries = parent.passwordStore.find(domain: host)
                guard !entries.isEmpty else { return }
                // Escape \ before ' — a raw backslash inside a secret would be
                // re-interpreted by the JS string literal.
                let username = entries[0].username.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                let password = entries[0].password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                let js = """
                (function() {
                    var f = document.querySelector('input[type=password]').closest('form');
                    if (!f) return;
                    var u = f.querySelector('input[name=\(usernameName)], input[id=\(usernameName)], input[type=text], input[type=email]');
                    if (u) u.value = '\(username)';
                    var p = f.querySelector('input[type=password]');
                    if (p) p.value = '\(password)';
                })();
                """
                parent.state.webView.evaluateJavaScript(js, completionHandler: nil)
            } else if message.name == "passwordSave", let dict = message.body as? [String: String],
                       let username = dict["username"], let password = dict["password"],
                       !username.isEmpty, !password.isEmpty,
                       let host = parent.state.webView.url?.host {
                if parent.passwordStore.isSuppressed(domain: host) { return }
                let existing = parent.passwordStore.find(domain: host)
                // Same username + same password = an ordinary re-login, not
                // worth a prompt. Same username + a different password is a
                // password change — offer to update instead of staying silent.
                if let match = existing.first(where: { $0.username == username }) {
                    guard match.password != password else { return }
                    // Non-blocking: the ContentView notice bar renders the prompt
                    // (a sheet here stole focus mid-Agent-task; an earlier
                    // runModal froze the whole app on every login submit).
                    parent.passwordStore.pendingSave?.respond(false)
                    parent.passwordStore.pendingSave = PendingPasswordSave(
                        domain: host, username: username, isUpdate: true
                    ) { [weak store = parent.passwordStore] save in
                        if save {
                            store?.updatePassword(match, to: password)
                        }
                        store?.pendingSave = nil
                    }
                    return
                }
                // Non-blocking: the ContentView notice bar renders the prompt
                // (a sheet here stole focus mid-Agent-task; an earlier
                // runModal froze the whole app on every login submit).
                parent.passwordStore.pendingSave?.respond(false)
                parent.passwordStore.pendingSave = PendingPasswordSave(
                    domain: host, username: username
                ) { [weak store = parent.passwordStore] save in
                    if save {
                        store?.save(domain: host, username: username, password: password)
                    }
                    store?.pendingSave = nil
                }
            } else if message.name == "readerContent", let dict = message.body as? [String: String] {
                parent.state.readerTitle = dict["title"] ?? ""
                parent.state.readerContent = dict["html"] ?? dict["content"] ?? ""
                parent.state.isReaderLoading = false
            } else if message.name == "hoverLink", let url = message.body as? String {
                parent.state.hoveredLinkURL = url.isEmpty ? nil : url
            } else if message.name == "middleClickLink", let raw = message.body as? String {
                // Middle-click (auxiliary button) on a link — the injected
                // middle-click.js already resolved it against the page URL.
                if let url = URL(string: raw) {
                    parent.onOpenLinkInNewTab?(url)
                }
            } else if message.name == "selectionAI", let dict = message.body as? [String: Any] {
                let text = dict["text"] as? String ?? ""
                if text.isEmpty {
                    parent.state.selectionAI = nil
                } else if let x = (dict["x"] as? NSNumber)?.doubleValue,
                          let y = (dict["y"] as? NSNumber)?.doubleValue {
                    parent.state.selectionAI = SelectionAIInfo(text: text, viewportX: x, viewportY: y)
                }
            } else if message.name == "elementPicker", let dict = message.body as? [String: String],
                      let selector = dict["cssSelector"] {
                let xpath = dict["xpath"]
                if let aiHandler = parent.state.onAIElementPicked {
                    let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                    parent.state.webView.evaluateJavaScript("""
                    (function() {
                        var el = document.querySelector('\(escaped)');
                        return el ? el.outerHTML.substring(0, 2000) : '';
                    })()
                    """) { result, _ in
                        if let html = result as? String {
                            aiHandler(selector, html)
                        }
                    }
                } else {
                    parent.onElementPicked?(selector, xpath)
                }
            } else if message.name == "mediaFound", let dict = message.body as? [String: Any],
                      let url = dict["url"] as? String, !url.isEmpty {
                let resource = MediaResource(
                    url: url,
                    kind: MediaResource.Kind(rawValue: dict["kind"] as? String ?? "video") ?? .video,
                    mime: dict["mime"] as? String ?? "",
                    sizeBytes: dict["size"] as? Int ?? 0,
                    source: dict["source"] as? String ?? "network",
                    detectedAt: Date()
                )
                parent.state.record(detectedMedia: resource)
            } else if message.name == "videoAdBlocked", let dict = message.body as? [String: Any],
                      let count = dict["count"] as? Int, count > 0 {
                // Forward to the optional closure so the host can show a toast.
                parent.onVideoAdBlocked?(count, dict["site"] as? String, dict["action"] as? String)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // A new navigation invalidates the previous failure — without
            // this, the error page kept covering the NEW page whenever the
            // old error was set right before a successful reload.
            parent.state.lastError = nil
            parent.isLoading = true
            parent.state.estimatedProgress = 0
            parent.state.lastError = nil
            parent.state.serverTrust = nil
            parent.state.hoveredLinkURL = nil
            parent.state.mixedContentTotal = 0
            parent.state.mixedContentScripts = 0
            parent.state.pendingOTPHint = nil
            // Workaround for WebKit Bug 313542 (https://bugs.webkit.org/show_bug.cgi?id=313542):
            // `customUserAgent` is not applied to the FIRST navigation request
            // when the URL is loaded via `load(_:)` — it only takes effect for
            // links the user taps inside the page. Re-applying it on every
            // provisional-navigation start ensures the very first request
            // (address-bar loads, programmatic loads, redirects) carries the
            // full Safari UA, which Cloudflare and other WAFs require to skip
            // the "由 Cloudflare 提供的性能和安全服务" challenge.
            BrowserState.applyDesktopSafariUA(to: webView)
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            parent.state.serverTrust = serverTrust

            var error: CFError?
            let isTrusted = SecTrustEvaluateWithError(serverTrust, &error)

            if isTrusted {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
            } else {
                let host = challenge.protectionSpace.host
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Invalid Certificate")
                    let errDesc = error?.localizedDescription ?? String(localized: "Unknown Error")
                    alert.informativeText = String(localized: "The certificate for \(host) is not trusted.\n\n\(errDesc)")
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: String(localized: "Continue Anyway"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        let credential = URLCredential(trust: serverTrust)
                        completionHandler(.useCredential, credential)
                    } else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Response headers arrived — the watchdog did its job.
            disarmLoadTimeout()
            // New page — the sniffed media list belongs to the old one.
            parent.state.detectedMedia.removeAll()
            parent.state.isSecure = webView.url?.scheme == "https"
            pendingUpgrades.removeAll()
            if let host = webView.url?.host {
                // Always assign — pageZoom persists per webview, so
                // without an explicit reset a previous site's zoom leaks
                // into sites with no saved value.
                let savedZoom = parent.siteSettingsStore.zoom(for: host)
                webView.pageZoom = savedZoom
                parent.state.pageZoom = savedZoom
            }
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
                BridgeEventBus.shared.publish("pageReady", [
                    "url": url.absoluteString,
                    // pageTitle KVO lands later — prefer the live title.
                    "title": webView.title ?? parent.state.pageTitle,
                ])

                // Inject content scripts from Safari extensions
                if let extensionManager = parent.extensionManager {
                    extensionManager.injectContentScripts(into: webView, for: url)
                }
            }
            if let host = webView.url?.host, parent.siteSettingsStore.darkModeEnabled(for: host) {
                webView.evaluateJavaScript(UserScriptLoader.load("dark-mode-inject"), completionHandler: nil)
            }
            // YouTube 赞助商片段跳过（SponsorBlock 数据，确定性脚本）。
            if parent.sponsorBlockEnabled,
               let host = webView.url?.host,
               host.hasSuffix("youtube.com") {
                let categories = parent.sponsorBlockCategories
                let categoriesJSON = (try? JSONSerialization.data(withJSONObject: categories))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let script = "window.__desireSBCategories = \(categoriesJSON);\n"
                    + UserScriptLoader.load("sponsorblock")
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
            if let host = webView.url?.host, let js = parent.state.videoAdBlocker?.pageScript(for: host) {
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            if let host = webView.url?.host {
                let rules = parent.elementBlockStore.matchingRules(for: host)
                let cssSelectors = rules.map(\.cssSelector).filter { !$0.isEmpty }
                let xpathRules = rules.compactMap { $0.xpath }.filter { !$0.isEmpty }
                if !cssSelectors.isEmpty {
                    let css = cssSelectors.map { "\($0) { display: none !important; }" }.joined()
                    webView.evaluateJavaScript("""
                    (function() {
                        var s = document.createElement('style');
                        s.id = 'desire-blocked-selectors';
                        s.textContent = '\(css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))';
                        document.head.appendChild(s);
                    })();
                    """, completionHandler: nil)
                }
                for xpath in xpathRules {
                    let escaped = xpath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                    webView.evaluateJavaScript("""
                    try {
                        var el = document.evaluate('\(escaped)', document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
                        if (el) el.style.display = 'none';
                    } catch(e) {}
                    """, completionHandler: nil)
                }
            }
            if parent.formAutofillStore.isConfigured {
                webView.evaluateJavaScript(parent.formAutofillStore.fillScript, completionHandler: nil)
            }
            // 页面批注恢复（0.3.7）：按 URL 文本锚定重新包裹高亮。
            if let url = webView.url?.absoluteString {
                let highlights = AnnotationStore.shared.highlights(for: url)
                    .map { ["text": $0.text, "colorIndex": $0.colorIndex] }
                if !highlights.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: highlights),
                   let json = String(data: data, encoding: .utf8) {
                    webView.evaluateJavaScript(
                        "__desireRestoreHighlights(\(json))", completionHandler: nil)
                }
            }
            // 混合内容扫描（0.2.15 加固）：https 页面统计 http:// 子资源。
            // 一次被动扫描（didFinish 时 DOM 已就绪）；延迟写入的脚本由
            // 下一轮导航或手动刷新再捕获。
            if webView.url?.scheme == "https" {
                webView.evaluateJavaScript(WebView.mixedContentScanJS) { value, _ in
                    guard let dict = value as? [String: Int],
                          let total = dict["total"], let scripts = dict["scripts"] else { return }
                    self.parent.state.mixedContentTotal = total
                    self.parent.state.mixedContentScripts = scripts
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.agent.error("didFail: \(error.localizedDescription, privacy: .public)")
            disarmLoadTimeout()
            parent.isLoading = false
            // Store the underlying `Error` so ErrorPageView can map
            // `URLError.code` to category-specific copy (TLS, offline, …)
            // instead of just dumping the raw localized description.
            parent.state.lastError = error
        }

        /// Hands a custom-scheme URL (tg://, spotify://, zoommtg:// …) to
        /// LaunchServices with a Safari-style confirmation naming the handler
        /// app — a page must not be able to launch arbitrary applications
        /// silently. Shows "no app found" when nothing is registered.
        private func confirmAndOpenExternalURL(_ url: URL, from webView: WKWebView) {
            Log.agent.error("EXTERNAL HANDOFF entered for \(url.absoluteString, privacy: .public)")
            let appURL = NSWorkspace.shared.urlForApplication(toOpen: url)
            let bundle = appURL.flatMap(Bundle.init(url:))
            let appName = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle?.infoDictionary?["CFBundleName"] as? String
                ?? url.scheme?.uppercased()
                ?? String(localized: "the external application")

            // Sheet-modal, NOT runModal: a modal here blocks the main
            // thread AND the navigation delegate mid-decision.
            guard let window = webView.window else { return }

            guard appURL != nil else {
                let alert = NSAlert()
                alert.messageText = String(localized: "No application can open this link")
                alert.informativeText = String(localized: "Desire couldn't find an app registered for:\n\(url.absoluteString)")
                alert.beginSheetModal(for: window, completionHandler: nil)
                return
            }

            let alert = NSAlert()
            alert.messageText = String(localized: "Open \(appName)?")
            alert.informativeText = String(localized: "This page wants to open:\n\(url.absoluteString)")
            alert.addButton(withTitle: String(localized: "Open"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                NSWorkspace.shared.open(url)
            }
        }

        // 处理新窗口/弹窗（Google 登录 OAuth 需要）
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            Log.agent.debug("decidePolicy: \(url.absoluteString, privacy: .public) scheme=\(url.scheme ?? "nil", privacy: .public) type=\(navigationAction.navigationType.rawValue) targetFrame=\(navigationAction.targetFrame != nil)")
            if let scheme = url.scheme?.lowercased(), !Self.internalSchemes.contains(scheme) {
                // Custom application scheme (tg://, spotify://, zoommtg://,
                // vscode:// …) — hand it to the OS so the registered desktop
                // app opens. Anything LaunchServices can't handle surfaces
                // in the confirmation dialog as "no app found".
                decisionHandler(.cancel)
                confirmAndOpenExternalURL(url, from: webView)
                return
            }

            // If this navigation was initiated by a back/forward gesture or
            // reload (WebKit's UI commands, our goBack()/goForward(), or a
            // user-triggered reload from the toolbar), don't intercept it.
            // The previous version called `webView.load(url)` here, which
            // produced a brand-new history entry on every back, breaking the
            // back button on sites like Bilibili where pages check history
            // depth / referrer for navigation state.
            if navigationAction.navigationType == .backForward ||
               navigationAction.navigationType == .reload {
                decisionHandler(.allow)
                return
            }

            // Frame-less navigation (e.g. target=_blank, window.open from JS).
            // Open in a new tab instead of allowing WebKit to open a new window.
            if navigationAction.targetFrame == nil {
                if let url = navigationAction.request.url {
                    parent.onOpenLinkInNewTab?(url)
                }
                decisionHandler(.cancel)
                return
            }

            // Cmd+点击链接 — 后台打开新标签
            if navigationAction.modifierFlags.contains(.command) {
                parent.onOpenLinkInNewTab?(url)
                decisionHandler(.cancel)
                return
            }

            // beforeunload 表单保护：主框架导航离开当前文档前，先执行页面
            // 自己注册的 beforeunload 监听器；页面拒绝离开时弹 sheet 询问。
            // 覆盖 .linkActivated/.formSubmitted/.other（含地址栏与 JS 跳转）。
            // back/forward 与 reload 沿用上面"不拦截"的既定策略——地址栏
            // 输入(.other)才是表单数据的主要丢失场景。
            if navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.navigationType == .linkActivated ||
               navigationAction.navigationType == .formSubmitted ||
               navigationAction.navigationType == .other {
                runBeforeUnloadGuard(webView: webView) { allowed in
                    decisionHandler(allowed ? .allow : .cancel)
                }
                return
            }

            // HTTPS 升级
            // Only upgrade when the user navigated to the URL by clicking a
            // link / typing into the address bar (`.linkActivated`,
            // `.other`, `.formSubmitted`). Skip for back/forward, reload, and
            // history restorations so the back button doesn't loop
            // http→https→http→https on sites that already do their own
            // scheme handling (Bilibili does this for /video/BV* redirects).
            if parent.httpsUpgradeEnabled,
               url.scheme == "http",
               navigationAction.targetFrame?.isMainFrame == true,
               // Loopback has no TLS server — upgrading hangs forever.
               !["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
               !fallbackInProgress.contains(url.absoluteString),
               navigationAction.navigationType == .other ||
               navigationAction.navigationType == .linkActivated ||
               navigationAction.navigationType == .formSubmitted {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.scheme = "https"
                if let https = comps?.url {
                    pendingUpgrades[https.absoluteString] = url
                    webView.load(URLRequest(url: https))
                    decisionHandler(.cancel)
                    return
                }
            }

            if navigationAction.targetFrame?.isMainFrame == true {
                armLoadTimeout(for: url)
            }
            decisionHandler(.allow)
        }

        /// Main-frame load watchdog: a server that never responds used to
        /// leave an eternal blank page with zero feedback. 30s → timeout
        /// error page (driven by lastError, same as network failures).
        /// Set by the watchdog before stopLoading() — the resulting
        /// cancelled (-999) provisional failure must NOT overwrite the
        /// meaningful timedOut error we just injected.
        private var suppressNextFailError = false

        private func armLoadTimeout(for url: URL) {
            loadTimeoutTask?.cancel()
            suppressNextFailError = false
            loadTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.parent.isLoading else { return }   // finished meanwhile
                Log.agent.error("load timeout: \(url.absoluteString, privacy: .public)")
                self.suppressNextFailError = true
                self.parent.state.lastError = URLError(
                    .timedOut,
                    userInfo: [NSURLErrorFailingURLErrorKey: url]
                )
                self.parent.state.webView.stopLoading()
                self.parent.isLoading = false
            }
        }

        /// Schemes the webview itself renders or owns. Every OTHER scheme
        /// is treated as an external application scheme and handed to
        /// LaunchServices (see confirmAndOpenExternalURL).
        private static let internalSchemes: Set<String> = [
            "http", "https", "about", "desire", "file", "blob", "data", "javascript", "ws", "wss",
        ]

        // 无法展示的 MIME 类型（.pkg/.dmg/.zip 等直接文件链接）转为下载，
        // 否则 WebKit 会尝试渲染并失败（code 102 "frame load interrupted"）
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // Real network capture (0.1.14): main-frame responses land in
            // the DevTools network panel. WebKit exposes no per-subresource
            // request API, so this is v1's honest coverage — the panel used
            // to contain ONLY preview placeholders.
            if let url = navigationResponse.response.url {
                let http = navigationResponse.response as? HTTPURLResponse
                let statusCode = http?.statusCode ?? 0
                let mime = navigationResponse.response.mimeType
                var headers: [String: String]?
                if let allHeaders = http?.allHeaderFields as? [String: Any] {
                    var plain: [String: String] = [:]
                    for (key, value) in allHeaders {
                        plain["\(key)"] = "\(value)"
                    }
                    headers = plain
                }
                let resourceType: NetworkRequest.ResourceType = navigationResponse.isForMainFrame ? .document : .other
                let requestID = parent.devToolsStore.startNetworkRequest(
                    url: url.absoluteString,
                    method: "GET",
                    resourceType: resourceType
                )
                parent.devToolsStore.completeNetworkRequest(
                    id: requestID,
                    statusCode: statusCode,
                    statusText: nil,
                    mimeType: mime,
                    responseHeaders: headers,
                    responseBody: nil
                )
            }
            if !navigationResponse.canShowMIMEType {
                // 高危类型落地确认（0.2.15 加固）：安装器/可执行脚本/磁盘
                // 镜像先取消本次导航，挂起非阻塞确认条（模态 NSAlert 会
                // 冻结自动化桥——密码保存条的同款教训）。确认后白名单
                // 放行一次。
                let responseURL = navigationResponse.response.url
                if UserDefaults.standard.object(forKey: "warnDangerousDownloads") as? Bool ?? true,
                   DownloadStore.isDangerousType(navigationResponse.response),
                   let responseURL,
                   !parent.state.dangerousDownloadAllowedURLs.contains(responseURL.absoluteString) {
                    let name = navigationResponse.response.suggestedFilename
                        ?? responseURL.lastPathComponent
                    parent.state.pendingDangerousDownload = PendingDangerousDownload(
                        url: responseURL, filename: name
                    ) { [weak state = parent.state, weak webView] allow in
                        // 无论放行与否都摘条（respond 只置 resolved，不清
                        // published 字段——密码保存条同款收尾）。
                        state?.pendingDangerousDownload = nil
                        if allow, let webView {
                            state?.dangerousDownloadAllowedURLs.insert(responseURL.absoluteString)
                            webView.load(URLRequest(url: responseURL))
                        }
                    }
                    decisionHandler(.cancel)
                    return
                }
                if let responseURL {
                    parent.state.dangerousDownloadAllowedURLs.remove(responseURL.absoluteString)
                }
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Log.agent.error("didFailProvisional: \(error.localizedDescription, privacy: .public)")
            disarmLoadTimeout()
            // The watchdog's own stopLoading cancels the navigation (-999);
            // keep the meaningful timedOut error it already injected.
            if suppressNextFailError, (error as? URLError)?.code == .cancelled {
                suppressNextFailError = false
                parent.isLoading = false
                return
            }
            suppressNextFailError = false
            parent.isLoading = false
            parent.state.lastError = error
            // Only fall back from HTTPS → HTTP when the *upgrade itself*
            // failed with a real network error. The previous version
            // triggered fallback on any non-cancelled error, which caused
            // problems when the user pressed back: the in-flight upgrade
            // navigation gets cancelled by the back action, the cancelled
            // (URLSession `-999`) error is non-cancelled under some macOS
            // builds, and we'd then issue a brand-new HTTP request on top
            // of the back navigation, corrupting history. Restrict the
            // fallback to a small set of well-known error codes that only
            // fire when the server itself couldn't be reached over HTTPS.
            guard let urlError = error as? URLError,
                  let failingURL = urlError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
                  let httpURL = pendingUpgrades.removeValue(forKey: failingURL.absoluteString) else { return }
            switch urlError.code {
            case .serverCertificateUntrusted,
                 .secureConnectionFailed,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .dnsLookupFailed:
                fallbackInProgress.insert(httpURL.absoluteString)
                webView.load(URLRequest(url: httpURL))
            case .cancelled:
                break
            default:
                break
            }
        }

        // MARK: - WKUIDelegate - 新窗口

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(), !Self.internalSchemes.contains(scheme) {
                // window.open("tg://…") and friends: launch the app instead
                // of leaving a blank new tab behind.
                confirmAndOpenExternalURL(url, from: webView)
                return nil
            }
            if let url = navigationAction.request.url {
                // 在后台线程中创建新标签页，然后立即导航
                Task { @MainActor in
                    parent.onOpenLinkInNewTab?(url)
                }
            }
            // 返回 nil 表示我们不需要额外的 WebView，新标签页会由 TabManager 创建
            return nil
        }

        // MARK: - WKUIDelegate - beforeunload 表单保护

        /// Synthetic beforeunload dispatch. This WebKit build never fires
        /// the unload event for gesture-less unloads (verified empirically:
        /// the native `runJavaScriptBeforeUnloadConfirmPanelWithMessage`
        /// hook is never consulted, and a `sendBeacon` inside a registered
        /// handler never fires — neither for `load()` nor in-page JS
        /// navigations), so the navigation DECISION point dispatches the
        /// page's own listeners manually. `allowed` is false only when the
        /// page objects AND the user (or the automation bridge) chose to
        /// stay.
        private func runBeforeUnloadGuard(webView: WKWebView, completion: @escaping (Bool) -> Void) {
            webView.evaluateJavaScript(Self.beforeUnloadProbeJS) { [weak self] result, _ in
                let payload = (result as? String).flatMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
                guard payload?["blocked"] as? Bool == true else {
                    // Page doesn't object (or no handlers) — allow.
                    completion(true)
                    return
                }
                let message = payload?["message"] as? String ?? ""
                Task { @MainActor [weak self] in
                    self?.confirmLeave(webView: webView, pageMessage: message, completion: completion)
                }
            }
        }

        /// Probe JS: runs the page's beforeunload listeners synchronously
        /// (property handler + addEventListener via dispatchEvent) and
        /// reports whether the page objects, plus any legacy return-string
        /// message. The property handler is invoked by hand — it would
        /// otherwise run twice (once here, once inside dispatchEvent).
        static let beforeUnloadProbeJS = """
        (function(){
          var e = new Event('beforeunload', {cancelable: true});
          var blocked = false;
          var message = '';
          var prop = window.onbeforeunload;
          if (typeof prop === 'function') {
            window.onbeforeunload = null;
            try {
              var legacy = prop(e);
              if (!(legacy === null || legacy === undefined || legacy === '')) {
                blocked = true;
                message = String(legacy);
              }
            } catch (err) {}
          }
          try { window.dispatchEvent(e); } catch (err) { blocked = true; }
          window.onbeforeunload = prop;
          return JSON.stringify({blocked: !!(blocked || e.defaultPrevented), message: message});
        })()
        """

        @MainActor
        private func confirmLeave(webView: WKWebView, pageMessage: String, completion: @escaping (Bool) -> Void) {
            // A prompt is already up (rapid double navigation): the first
            // decision stays authoritative; later navigations just proceed.
            guard parent.state.pendingBeforeUnload == nil else {
                completion(true)
                return
            }
            // The ContentView notice bar renders the prompt (non-blocking).
            let pending = PendingBeforeUnload(message: pageMessage) { [weak state = parent.state] decision in
                state?.pendingBeforeUnload = nil
                completion(decision)
            }
            parent.state.pendingBeforeUnload = pending
            BridgeEventBus.shared.publish("beforeunloadPending", [
                "url": webView.url?.absoluteString ?? "",
                "message": pageMessage,
            ])
        }

        // MARK: - WKUIDelegate - element fullscreen

        /// Auto-approve the element-fullscreen prompt. Not in the public
        /// SDK headers (WebKit finds this selector at runtime); without it
        /// WebKit shows its own confirm dialog / second window. Pair with
        /// the fullscreenState KVO that drives the window fullscreen.
        @objc func webView(_ webView: WKWebView, runJavaScriptFullScreenPromptForUserWithMessage message: String, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }

        // MARK: - WKUIDelegate - 权限请求

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let pType: PermissionType = switch type {
            case .camera: .camera
            case .microphone: .microphone
            case .cameraAndMicrophone: .cameraAndMicrophone
            @unknown default: .camera
            }
            let host = origin.host
            if let saved = parent.permissionStore.decision(for: host, type: pType) {
                decisionHandler(saved == .allow ? .grant : .deny)
                return
            }
            let deviceName: String = switch type {
            case .camera: String(localized: "Camera")
            case .microphone: String(localized: "Microphone")
            case .cameraAndMicrophone: String(localized: "Camera and Microphone")
            @unknown default: String(localized: "Media Device")
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "\(host) wants to access your \(deviceName)")
            alert.informativeText = String(localized: "Allow this website to access your \(deviceName)?")
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Deny"))
            let checkbox = NSButton(checkboxWithTitle: String(localized: "Remember this decision"), target: nil, action: nil)
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if checkbox.state == .on {
                parent.permissionStore.set(host: host, type: pType, decision: response == .alertFirstButtonReturn ? .allow : .deny)
            }
            decisionHandler(response == .alertFirstButtonReturn ? .grant : .deny)
        }

        func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            let host = origin.host
            if let saved = parent.permissionStore.decision(for: host, type: .geolocation) {
                decisionHandler(saved == .allow ? .grant : .deny)
                return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "\(host) wants to access your location")
            alert.informativeText = String(localized: "Allow this website to access your location?")
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Deny"))
            let checkbox = NSButton(checkboxWithTitle: String(localized: "Remember this decision"), target: nil, action: nil)
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if checkbox.state == .on {
                parent.permissionStore.set(host: host, type: .geolocation, decision: response == .alertFirstButtonReturn ? .allow : .deny)
            }
            decisionHandler(response == .alertFirstButtonReturn ? .grant : .deny)
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            // Agent upload intent (setUploadFile): auto-submit the armed
            // file instead of showing the panel — this is what lets the
            // agent publish videos to upload pages.
            if let urls = UploadIntent.shared.consume(allowMultiple: parameters.allowsMultipleSelection) {
                completionHandler(urls)
                return
            }
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
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            return alert.runModal() == .alertFirstButtonReturn
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = prompt
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return textField.stringValue
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            let filename = download.originalRequest?.url?.lastPathComponent ?? String(localized: "Download")
            let sourceURL = download.originalRequest?.url
            let id = UUID()
            var item = DownloadItem(
                id: id,
                filename: filename,
                fileURL: nil,
                totalBytes: 0,
                downloadedBytes: 0,
                state: .inProgress,
                error: nil,
                cancel: { [weak download, weak store = parent.downloadStore] in
                    download?.cancel { resumeData in
                        Task { @MainActor [weak store] in
                            store?.storeResumeData(resumeData, for: id)
                        }
                    }
                },
                sourceURL: sourceURL
            )
            // Incognito tab → the row must never reach the shared download
            // history on disk.
            item.isPrivate = parent.state.isIncognito
            // REAL pause for webview downloads: WKDownload cannot be
            // suspended, so pausing cancels it while producing resume data;
            // resuming restarts from the partial file (see resumeDownload).
            item.pauseAction = { [weak download, weak store = parent.downloadStore] in
                download?.cancel { resumeData in
                    Task { @MainActor [weak store] in
                        store?.storeResumeData(resumeData, for: id)
                    }
                }
            }
            item.resumeAction = { [weak self] data in
                Task { await self?.resumeDownload(data, itemID: id) }
            }
            parent.downloadStore.add(item: item)
            let observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor [weak self] in
                    self?.parent.downloadStore.updateProgress(
                        id: id,
                        totalBytes: progress.totalUnitCount,
                        downloadedBytes: progress.completedUnitCount
                    )
                }
            }
            activeDownloads[ObjectIdentifier(download)] = DownloadInfo(id: id, progressObservation: observation)
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let destination: URL
            if let partial = resumeDestinations[ObjectIdentifier(download)] {
                // Resumed download — continue into the SAME partial file.
                destination = partial
            } else {
                destination = parent.downloadStore.uniqueURL(for: suggestedFilename)
            }
            resumeDestinations.removeValue(forKey: ObjectIdentifier(download))
            if let info = activeDownloads[ObjectIdentifier(download)] {
                parent.downloadStore.setDestination(
                    id: info.id,
                    filename: suggestedFilename,
                    fileURL: destination,
                    totalBytes: response.expectedContentLength
                )
            }
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            if let info = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) {
                parent.downloadStore.complete(id: info.id)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            guard let info = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
            // Pausing a webview download surfaces here as a cancel — keep the
            // item paused with its resume data instead of failing it. Capture
            // the flag BEFORE storeResumeData: a parked resume request fires
            // inside it and clears isPaused.
            let wasPaused = parent.downloadStore.downloads.first(where: { $0.id == info.id })?.isPaused == true
            parent.downloadStore.storeResumeData(resumeData, for: info.id)
            if wasPaused { return }
            parent.downloadStore.fail(id: info.id, message: DownloadStore.DownloadFailure.describe(error))
        }

        /// Restores a paused/failed webview download from its resume data,
        /// keeping the SAME item id and (when known) the SAME partial
        /// destination file so progress and completion land on the original row.
        func resumeDownload(_ resumeData: Data?, itemID: UUID) async {
            guard let resumeData, !resumeData.isEmpty else { return }
            let download = await parent.state.webView.resumeDownload(fromResumeData: resumeData)
            download.delegate = self
            let destination = parent.downloadStore.downloads.first(where: { $0.id == itemID })?.fileURL
            resumeDestinations[ObjectIdentifier(download)] = destination
            let observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor [weak self] in
                    self?.parent.downloadStore.updateProgress(
                        id: itemID,
                        totalBytes: progress.totalUnitCount,
                        downloadedBytes: progress.completedUnitCount
                    )
                }
            }
            activeDownloads[ObjectIdentifier(download)] = DownloadInfo(id: itemID, progressObservation: observation)
        }
    }
}
