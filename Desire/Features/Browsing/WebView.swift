import AppKit
import ObjectiveC
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
    /// 二级挂起会**重建**此视图（释放旧骨架、换上空白新视图）——除本类型
    /// 的 rebuildWebView() 外不得赋值；读取方照旧（非 optional，永不 nil）。
    private(set) var webView: BrowserWKWebView
    /// 插件消息 handler（extensionWorld + per-plugin world）是否已注册——
    /// Coordinator.observe() 置位、stopObserving() 复位。新 webview 的首次
    /// 加载可能快于 SwiftUI 建 representable，内容脚本此时 postMessage 会
    /// 静默丢失（WebKit 丢给未接线的 handler 名，不抛错）——didFinish 的
    /// 插件注入在未就绪时改为挂起，注册完成后补跑（consumePendingPluginInject）。
    var areExtHandlersRegistered = false
    /// 挂起中的插件注入（值 = didFinish 的页面 URL）。
    var pendingPluginInjectURL: URL?
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
    /// **内建 PDF 查看器**：主框架导航落 PDF 且 WKWebView 不显示时，取消
    /// 导航、下载到本地临时文件、置此 URL——SelectedTabContent 渲染
    /// PDFViewerView（PDFKit）。nil = 非 PDF 查看态。关闭 = 置 nil 并回
    /// 原 URL（viewerReturnURL）。
    @Published var pdfViewerURL: URL?
    /// PDF 查看器关闭时返回的页面地址。
    @Published var pdfViewerReturnURL: URL?
    /// PDF 下载中（主框架 PDF 导航的过渡态——渲染进度条而非白页）。
    @Published var isPDFLoading = false
    /// **本地媒体查看器**（拖入 mp4/mov/webm/mp3 等）：AVPlayer 直接播
    /// 本地文件——不走 WKWebView file:// 媒体管线（受播放策略/进程状态
    /// 影响，实测出现过元数据不加载的假死且报错不可见）。
    @Published var mediaViewerURL: URL?
    @Published var mediaViewerFileName = ""
    /// 展示用文件名。
    @Published var pdfViewerFileName = ""
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

    /// 元素拾取器这次是给谁用的。
    ///
    /// 拾取器只有一条消息通道（`elementPicker`），但有三条消费链：DevTools 的
    /// Element 页签、元素屏蔽弹窗、AI 上下文。此前原生侧无条件优先 AI 分支，
    /// 于是 Element 页签永远是空的、屏蔽弹窗也弹不出来。现在由"谁启动拾取"
    /// 显式声明意图，原生侧按意图分发。
    enum ElementPickIntent { case block, devTools, ai }
    var elementPickIntent: ElementPickIntent = .block
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
        // HTML5 Fullscreen API 必须保持开启 —— 它就是视频全屏本身：WebKit
        // 会为全屏元素新建一个覆盖整屏的窗口（WebCoreFullScreenWindow）并把
        // 页面视口放大到整屏，视频层随之铺满。
        //
        // 历史教训（2026-09-20，三轮全屏返工的真根因）：全屏曾经"只有网页
        // 区域大小、四周黑边"，原因是注入的 fullscreen-shim 覆盖了
        // Element.prototype.requestFullscreen 做纯 CSS 满屏——原生 API 被
        // 覆盖后 WebKit 全屏管线永远不跑，元素只能被 CSS 钉在 webview 视口
        // （= 窗口减去 chrome）里。最小宿主对照实验已证实：同一份页面，
        // 不注入 shim → WebCoreFullScreenWindow + 视口 2560x1440（正常）；
        // 注入 shim → fullscreenState 停在 notInFullscreen、视口不变。
        // 结论：**任何覆盖 requestFullscreen/exitFullscreen 的注入脚本都
        // 会废掉全屏**，勿再引入（shim 文件与注册行已删除）。
        config.preferences.isElementFullscreenEnabled = true
        // Live Text / 图像分析（VisionKit）关闭：WebKit 会对页面里的视频帧
        // 自动跑文本提取，并在 webview 内装入 VKCImageAnalysis 浮层
        // （日志：[com.apple.WebKit:ImageAnalysis] Installing image analysis
        // overlay view）。该浮层在布局过渡（进入全屏、缩放、窗口尺寸变化）
        // 中以 0×0 bounds 计算出 NaN contentsRect，触发 AppKit 几何断言
        // 直接杀死进程（EXC_BREAKPOINT _NSViewValidateGeometry ←
        // VKCImageAnalysisBaseView/updateCurrentDisplayedViewContentsRect，
        // 2026-09-20 崩溃报告）。Desire 没有 Live Text UI，关掉最干净。
        // 键名无公开 API（WKWebView 无 allowsImageAnalysis），走 KVC —
        // 与本文件既有的 developerExtrasEnabled 同路。
        config.setValue(false, forKey: "systemTextExtractionEnabled")
        config.applicationNameForUserAgent = "Version/26.5 Safari/605.1.15"
        contentBlocker?.apply(to: config)
        // Network interception rules (0.1.13): block/redirect applied to
        // every new webview; late rules distribute to registered views.
        InterceptStore.shared.apply(to: config.userContentController)
        // Community filter lists (EasyList) — process-wide singleton.
        FilterListStore.shared.apply(to: config)
        // 插件 declarativeNetRequest 规则集（每插件一份编译好的列表）。
        PluginDNRStore.shared.apply(to: config.userContentController)
        if let videoAdBlocker, videoAdBlocker.isEnabled {
            config.userContentController.addUserScript(videoAdBlocker.documentStartScript())
            config.userContentController.addUserScript(videoAdBlocker.documentStartGuardScript())
            config.userContentController.addUserScript(videoAdBlocker.documentEndScript())
            config.userContentController.addUserScript(videoAdBlocker.documentEndAntiAdblockScript())
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
        // 每插件独立 world 也各注入一份（消息传递/background 通信在此 world
        // 跑——插件间身份与全局互不覆盖）。启动后新装的插件由 observe() 的
        // per-plugin handler 注册补齐；user script 是 webview 定格的，新插件
        // 的 world script 会在下一次导航的 webview 上生效（与 content script
        // 注入的时序一致）。
        if let pluginStore = AppState.live?.pluginStore {
            for plugin in pluginStore.plugins where plugin.isEnabled {
                // 必须落进该插件自己的 world——历史上这里重复加的是
                // extensionWorld 那份，per-plugin world 里 chrome 恒 undefined。
                if let script = UserScriptLoader.extensionAPIScript(in: WebView.pluginWorld(plugin.id)) {
                    config.userContentController.addUserScript(script)
                }
            }
            Log.userScripts.info("webview init: injected webext-api into \(pluginStore.plugins.filter { $0.isEnabled }.count, privacy: .public) plugin world(s)")
        }

        webView = Self.makeWebView(configuration: config)
        // Cookie-policy changes must reach this OPEN page too.
        PrivacyModeStore.shared.registerWebView(webView)
        // drawsBackground 保持默认（不透明）：0.3.9 曾用 KVC 关掉它试图
        // 消 resize 过场闪（8a880f6），历轮实测均未通过——透明内容让
        // WebKit 无法只拉伸旧帧过渡 resize，每帧合成页面背景反而加剧
        // 闪烁。勿再关闭。（UA/手势等实例级设置集中在 makeWebView。）
    }

    /// 统一的 webview 构造（init 与二级挂起重建共用）：UA、手势等
    /// 实例级设置全部集中在这。
    private static func makeWebView(configuration: WKWebViewConfiguration) -> BrowserWKWebView {
        let view = BrowserWKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = true
        // Set the full Safari 26.5 UA on the WKWebView instance itself.
        // (See `applyDesktopSafariUA(to:)` for why this is on the view, not
        // the configuration.)
        applyDesktopSafariUA(to: view)
        return view
    }

    /// 下载 PDF 到临时目录并进入查看器状态（重复查看同一 URL 复用已下文件，
    /// 带 HEAD 式大小/日期校验的成本太高——临时目录由系统清）。
    func presentPDFViewer(for url: URL, suggestedName: String) {
        let safeName = suggestedName.isEmpty ? url.lastPathComponent : suggestedName
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("desire-pdf-" + UUID().uuidString.prefix(8)
                + "-" + safeName)
        isPDFLoading = true
        pdfViewerURL = nil
        pdfViewerReturnURL = webView.url
        Task { [weak self] in
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 60
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 || response.url == url else {
                    throw URLError(.badServerResponse)
                }
                try data.write(to: local, options: .atomic)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    isPDFLoading = false
                    pdfViewerURL = local
                    self.pdfViewerFileName = safeName
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    isPDFLoading = false
                    // 回退原行为：直接再 load（落地白页，同旧版），但给出提示。
                    pdfViewerURL = nil
                    lastError = error
                }
            }
        }
    }

    /// 退出 PDF 查看器：清状态，回到进入前的页面。
    func dismissPDFViewer() {
        pdfViewerURL = nil
        if let back = pdfViewerReturnURL {
            pdfViewerReturnURL = nil
            webView.load(URLRequest(url: back))
        }
    }

    /// **二级挂起的 webview 重建**（PERF-9 完整版）：释放旧 WKWebView 骨架
    /// （13 个 script handler + 全套 userScript + WebKit 内部结构——挂起省
    /// 页面内存，骨架此前却常驻），换上同配置的空白新视图。挂起标签的
    /// UI 已是 SuspendedTabView（webview 不在视图层，representable 已
    /// dismantle、handler 已摘），工具路径对挂起标签本就拒绝——重建对
    /// 它们不可见。恢复 = Tab.restoreSuspendedState 的既有 URL 重载，
    /// makeNSView 重新 observe（remove-before-add 幂等）。Cookie 策略
    /// 注册照 init 同款：旧的随释放消亡（弱引用 box），新的注册。
    func rebuildWebView() {
        let config = webView.configuration
        let old = webView
        // 摘掉旧视图上的 delegate（stopObserving 只在 representable
        // dismantle 跑——挂起态它已经跑过；这里兜底再摘，幂等）。
        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        let fresh = Self.makeWebView(configuration: config)
        PrivacyModeStore.shared.registerWebView(fresh)
        fresh.loadHTMLString("", baseURL: nil)
        webView = fresh
        objectWillChange.send()
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
    /// 这个 webview 所属的标签页。调试面板的 store 是 app 级共享的，每条
    /// console / network 记录都要带上它才能按标签页过滤（见 DevToolsStore.TabScope）。
    let tabID: UUID
    @Binding var urlString: String
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    var httpsUpgradeEnabled: Bool = true
    /// YouTube 赞助商片段跳过开关（didFinish 注入 sponsorblock.js）。
    var sponsorBlockEnabled: Bool = false
    /// 启用的 SponsorBlock 类别（随开关注入页面）。
    var sponsorBlockCategories: [String] = []
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
    /// WebExtension tabs.update/get 用：返回本窗口的 TabManager。
    var onTabManager: (() -> TabManager?)?
    var onCreateTab: ((String) -> Void)?
    var onRemoveTab: ((String) -> Void)?
    @ObservedObject var elementBlockStore: ElementBlockStore

    /// 插件代码与 WebExtension API 运行在隔离 content world：页面 JS
    /// 看不到（也不能伪造）`browser.*`；DOM 共享，JS 全局隔离。
    static let extensionWorld = WKContentWorld.world(name: "desireExtensions")

    /// 每插件独立 world（扩展间隔离：`__desireExtID` 等身份变量不再互相覆盖）。
    /// handler 需注册到每个插件的 world（observe() 循环注册）。
    static func pluginWorld(_ id: UUID) -> WKContentWorld {
        WKContentWorld.world(name: "desirePlugin-" + id.uuidString)
    }

    // Computed (not `static let`) so the file is read from the bundle lazily
    // on first use rather than at type-init time, before Bundle.main is ready.
    static var pickerJS: String { UserScriptLoader.load("element-picker") }

    static var exitPickerJS: String { UserScriptLoader.load("element-picker-exit") }

    /// JS that counts total matches of `query` in the page's text nodes.
    /// Used by the find-in-page UI. NOTE: TreeWalker.nextNode() only returns
    /// a boolean — the text lives on `walk.currentNode.nodeValue` (using
    /// `walk.nodeValue` throws, which used to zero the match count).
    static func findCountJS(query: String) -> String {
        return """
        (function() {
            var t = \(JSString.literal(query));
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
        return """
        (function() {
            var s = document.getElementById('desire-blocked-\(ruleId.uuidString)');
            if (s) s.remove();
            document.querySelectorAll(\(JSString.literal(selector))).forEach(function(el) { el.style.display = ''; });
        })();
        """
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WebViewContainer {
        let webView = state.webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.onOpenLinkInNewTab = { url in
            context.coordinator.parent.onOpenLinkInNewTab?(url)
        }
        webView.onSearchText = { text in
            context.coordinator.parent.onSearchText?(text)
        }
        context.coordinator.observe(webView)
        // Container (not the web view itself) — see WebViewContainer for why
        // that indirection is what makes fullscreen video fill the screen.
        return WebViewContainer(webView: webView)
    }

        func updateNSView(_ nsView: WebViewContainer, context: Context) {
            context.coordinator.parent = self
            // per-plugin world 的 desireExt handler 是 webview 创建后装的插件才有的——
            // webview 复用不会重跑 makeNSView/observe，这里幂等补注册（remove-before-add）。
            context.coordinator.registerPluginWorldHandlers(nsView.webView, coordinator: context.coordinator)
            context.coordinator.consumePendingPluginInject(nsView.webView)
        }

    static func dismantleNSView(_ nsView: WebViewContainer, coordinator: Coordinator) {
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
        enum FileLinkKind {
            case download      // 归档/安装类：进下载面板
            case pdfViewer     // PDF：内建查看器
        }

        /// 归档/安装类扩展名（点开语义 = 下载保存；不猜渲染类格式——
        /// 音视频/图片让 WebKit 播，PDF 单独分流查看器，其余格式靠
        /// navigationResponse 的 mime 兜底转下载）。
        private static let archiveExtensions: Set<String> = [
            "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz",
            "dmg", "pkg", "exe", "msi", "iso", "apk", "deb", "rpm",
        ]

        /// 链接 URL 的文件类型分类（无扩展名/不认识的格式返回 nil）。
        static func classifyFileLink(_ url: URL) -> FileLinkKind? {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" { return .pdfViewer }
            if archiveExtensions.contains(ext) { return .download }
            return nil
        }

        private static let scriptMessageHandlers = [
            "audioState", "mediaFound", "passwordDetect", "passwordSave",
            "readerContent", "hoverLink", "middleClickLink", "selectionAI",
            "elementPicker", "videoAdBlocked", "devConsole", "netEntry",
            "otpDetect",
        ]

        /// desireExt handler 注册台账（associated object 挂 webview，见
        /// registerPluginWorldHandlers 的零折腾注释）。
        final class ExtHandlerLedger {
            var entries: [String: WKScriptMessageHandler] = [:]
        }
        static let extHandlerLedgerKey = "desireExtHandlerLedger"

        func observe(_ webView: WKWebView) {
            let contentController = webView.configuration.userContentController
            for name in Self.scriptMessageHandlers {
                // Remove-before-add makes re-hosting the same WKWebView
                // (fast tab switches recreate the representable) idempotent
                // instead of throwing on the duplicate name.
                contentController.removeScriptMessageHandler(forName: name)
                contentController.add(self, name: name)
            }
            // WebExtension RPC（extensionWorld + 各插件 world）——注册走
            // registerPluginWorldHandlers 的台账去重（observe 的 remove+add
            // 每次都换桥接对象，会丢导航瞬间在途消息，勿改回）。
            registerPluginWorldHandlers(webView, coordinator: self)
            // 登记本 tab 的 webview（tabs.sendMessage 的寻址表；快速切标签
            // 重建 representable 时 observe 重跑，登记随之刷新）。
            PluginBackgroundRuntime.shared.registerTabWebview(parent.tabID, webView: webView)
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
            // handler 全部就位：置就绪标志并补跑挂起中的插件注入
            //（首载快于 representable 建立时 didFinish 把注入挂起了）。
            parent.state.areExtHandlersRegistered = true
            consumePendingPluginInject(webView)
        }

        /// 补跑挂起中的插件注入（handler 注册先于 didFinish 时无挂起、空操作）。
        /// URL 不匹配（挂起后已再次导航）则丢弃——那次导航自己会走正常路径。
        func consumePendingPluginInject(_ webView: WKWebView) {
            guard let url = parent.state.pendingPluginInjectURL else { return }
            parent.state.pendingPluginInjectURL = nil
            guard webView.url?.absoluteString == url.absoluteString else { return }
            AppState.live?.pluginStore.inject(into: webView, for: url, tabID: parent.tabID)
        }

        // 全屏 = WebKit 原生 element fullscreen（见 BrowserState.init 的
        // HTML5 Fullscreen API 注释）：WebKit 自建整屏窗口、自动批准
        // JS 全屏请求、退出由页面/系统管。窗口级同步方案（shim +
        // fullscreenRequest + fullscreenState KVO）三轮实测均致黑屏，
        // 已整体移除——勿再引入。chrome 收起（只在站点整屏时）在
        // ContentView/SelectedTabContent（isSiteFullScreen）。

        /// per-plugin world 的 desireExt handler 注册（幂等 + **零折腾**）。
        /// webview 复用时 observe 不重跑——新装插件的 world 在这里补注册。
        /// **同 coordinator 已注册的 world 直接跳过**：曾经的 remove+add 在
        /// 每轮 updateNSView 都换一次桥接对象，把导航瞬间在途的脚本消息
        /// 丢掉（实测内容脚本首发消息必丢、延时 ≥300ms 才能存活）。
        func registerPluginWorldHandlers(_ webView: WKWebView, coordinator: Coordinator) {
            let contentController = webView.configuration.userContentController
            guard let pluginStore = AppState.live?.pluginStore else { return }
            let ledger = objc_getAssociatedObject(webView, Self.extHandlerLedgerKey)
                as? ExtHandlerLedger ?? ExtHandlerLedger()
            var newlyRegistered = 0
            func ensure(_ world: WKContentWorld, worldKey: String) {
                if ledger.entries[worldKey] === coordinator { return }
                contentController.removeScriptMessageHandler(
                    forName: "desireExt", contentWorld: world)
                contentController.add(coordinator, contentWorld: world, name: "desireExt")
                ledger.entries[worldKey] = coordinator
                newlyRegistered += 1
            }
            ensure(WebView.extensionWorld, worldKey: "__extension__")
            for plugin in pluginStore.plugins where plugin.isEnabled && !plugin.jsCode.isEmpty {
                ensure(WebView.pluginWorld(plugin.id), worldKey: plugin.id.uuidString)
            }
            objc_setAssociatedObject(webView, Self.extHandlerLedgerKey, ledger,
                                     .OBJC_ASSOCIATION_RETAIN)
            if newlyRegistered > 0 {
                Log.userScripts.info("plugin world handlers registered: \(newlyRegistered, privacy: .public)")
            }
        }

        func stopObserving() {
            observations.removeAll()
            let wv = parent.state.webView
            // P1-2：先 stopLoading（此时 delegate 还在，-999 取消错误会被
            // didFailProvisionalNavigation 接住、isLoading 正常复位），**再**
            // 摘 delegate——顺序反了取消错误无人接收，isLoading 永久卡 true，
            // 工具栏转圈永转。
            wv.stopLoading()
            for name in Self.scriptMessageHandlers {
                wv.configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
            wv.configuration.userContentController.removeScriptMessageHandler(
                forName: "desireExt", contentWorld: WebView.extensionWorld)
            // 台账一并作废（下次 observe 重新登记，与新 coordinator 配对）。
            objc_setAssociatedObject(wv, Self.extHandlerLedgerKey, nil, .OBJC_ASSOCIATION_RETAIN)
            parent.state.areExtHandlersRegistered = false
            ExtensionEventHub.shared.unregister(parent.state)
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.onOpenLinkInNewTab = nil
            wv.onOpenInContainer = nil
            wv.onSearchText = nil
        }

        /// WebExtension RPC（0.2.13）：隔离世界里 `browser.*` 的宿主侧。
        /// 协议：{id, ns, fn, args[]} → `_resolve(id, ok, payloadJSON)`，
        /// payload 以 JSON 字面量内嵌（存储值已在 set 时校验可序列化）。
        private func handleExtensionMessage(_ body: Any, world: WKContentWorld) {
            let dictForLog = body as? [String: Any]
            let nsText = dictForLog?["ns"] as? String ?? "?"
            let fnText = dictForLog?["fn"] as? String ?? "?"
            Log.userScripts.info("ext handler: \(nsText, privacy: .public)/\(fnText, privacy: .public)")
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
                    // JSString.literal 的转义集（\\ \" \n \r \uXXXX…）是 JSON
                    // 字符串转义的兼容超集——手工两段式曾漏 \r/\u2028。
                    json = JSString.literal(error)
                } else if let payload {
                    // NSJSONSerialization 默认拒绝 String/数字等**标量顶层**
                    // （抛 ObjC 异常且 try? 拦不住——scripting case 实测崩溃）。
                    // 标量手动字符串化，容器才走 JSONSerialization。
                    switch payload {
                    case let scalar as String:
                        json = JSString.literal(scalar)
                    case let number as NSNumber:
                        json = number.stringValue
                    case let bool as Bool:
                        json = bool ? "true" : "false"
                    default:
                        if JSONSerialization.isValidJSONObject(payload),
                           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                           let str = String(data: data, encoding: .utf8) {
                            json = str
                        } else {
                            // 非 JSON 容器（DOM 节点等 Objective-C 对象）：
                            // dataWithJSONObject 对它抛的是 ObjC 异常，try?
                            // 拦不住、进程直接 abort——必须先 isValid。
                            json = "null"
                        }
                    }
                } else {
                    json = "null"
                }
                let js = "window.__desireExt && window.__desireExt._resolve(\(id), \(error == nil), \(json))"
                parent.state.webView.evaluateJavaScript(
                    js, in: nil, in: world, completionHandler: nil)
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
            case ("tabs", "update"):
                // Chrome 语义：updateProperties {active, url, pinned}（tabId 从 args[0]）。
                guard args.count >= 2,
                      let tabIDString = args[0] as? String,
                      let props = args[1] as? [String: Any],
                      let tm = parent.onTabManager?(),
                      let target = tm.tabs.first(where: { $0.id.uuidString == tabIDString }),
                      let idx = tm.tabs.firstIndex(where: { $0.id == target.id }) else {
                    reply(nil, error: "tabs.update requires (tabId, props) with a valid tab")
                    return
                }
                if let active = props["active"] as? Bool, active { tm.selectTab(at: idx) }
                if let pinned = props["pinned"] as? Bool { target.isPinned = pinned }
                if let urlString = props["url"] as? String, let u = URL(string: urlString) {
                    target.urlString = urlString
                    target.browser.webView.load(URLRequest(url: u))
                }
                reply([:])
            case ("tabs", "get"):
                guard let tabIDString = args.first as? String,
                      let tm = parent.onTabManager?(),
                      let t = tm.tabs.first(where: { $0.id.uuidString == tabIDString }),
                      let idx = tm.tabs.firstIndex(where: { $0.id == t.id }) else {
                    reply(nil, error: "no such tab")
                    return
                }
                reply(["id": t.id.uuidString, "index": idx,
                       "url": t.browser.webView.url?.absoluteString ?? t.urlString,
                       "title": t.browser.pageTitle,
                       "active": idx == tm.selectedIndex,
                       "incognito": t.isIncognito, "pinned": t.isPinned])
            case ("tabs", "reload"):
                // 页面上下文的 reload（背景同款实现收口在 reloadTab）。
                if let err = PluginBackgroundRuntime.reloadTab(parent.onTabManager?(),
                                            tabIDString: args.first as? String) {
                    reply(nil, error: err)
                } else {
                    reply([:])
                }
            case ("windows", "create"):
                if let url = (args.first as? [String: Any])?["url"] as? String, !url.isEmpty {
                    parent.onCreateTab?(url)
                    reply([:])
                } else {
                    reply(nil, error: "windows.create requires {url}")
                }
            case ("windows", "getAll"):
                let managers = TabSessionCoordinator.shared.liveManagers()
                let wins = managers.enumerated().map { wi, manager -> [String: Any] in
                    ["id": wi,
                     "tabs": manager.tabs.enumerated().map { tidx, t in
                         ["id": t.id.uuidString, "index": tidx,
                          "url": t.browser.webView.url?.absoluteString ?? t.urlString,
                          "title": t.browser.pageTitle] as [String: Any]
                     }]
                }
                reply(Array(wins))
            case ("scripting", "executeScript"), ("scripting", "insertCSS"):
                // MV3 动态注入（宿主侧收口在 PluginBackgroundRuntime.runScripting，
                // 页面/背景 handler 共用；files[] 从插件包资源目录读）。
                guard let details = args.first as? [String: Any] else {
                    reply(nil, error: "scripting requires details")
                    return
                }
                let pluginUUID = extID.flatMap(UUID.init(uuidString:))
                guard let pluginUUID else {
                    reply(nil, error: "no extension identity")
                    return
                }
                PluginBackgroundRuntime.runScripting(
                    details: details, pluginID: pluginUUID,
                    resourcesPath: PluginBackgroundRuntime.shared
                        .resourcesPath(for: pluginUUID),
                    op: fn == "executeScript" ? .execute
                        : (fn == "insertCSS" ? .insert : .remove),
                    fallbackWebView: parent.state.webView) { value, error in
                    reply(value, error: error)
                }
            case ("cookies", "getAll"):
                let filterURL = (args.first as? [String: Any])?["url"]
                    .flatMap { $0 as? String }.flatMap { URL(string: $0) }
                parent.state.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    var list: [[String: Any]] = []
                    for c in cookies {
                        if let fu = filterURL {
                            guard c.domain.hasSuffix(fu.host ?? "#")
                                  || fu.host?.hasSuffix(c.domain) == true else { continue }
                        }
                        list.append(["domain": c.domain, "name": c.name,
                                     "value": c.value, "path": c.path,
                                     "secure": c.isSecure] as [String: Any])
                    }
                    reply(list)
                }
            case ("cookies", "get"):
                guard let details = args.first as? [String: Any],
                      let name = details["name"] as? String else {
                    reply(nil, error: "cookies.get requires name")
                    return
                }
                parent.state.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let hit = cookies.first { $0.name == name }
                    reply(hit.map { ["domain": $0.domain, "name": $0.name,
                                     "value": $0.value, "path": $0.path] }
                          ?? NSNull())
                }
            case ("cookies", "set"):
                guard let setDetails = args.first as? [String: Any],
                      let name = setDetails["name"] as? String,
                      let value = setDetails["value"] as? String else {
                    reply(nil, error: "cookies.set requires name/value")
                    return
                }
                // Chrome 语义：domain 可省——从 url 的 host 推导。
                let domain: String
                if let explicit = setDetails["domain"] as? String, !explicit.isEmpty {
                    domain = explicit
                } else if let urlString = setDetails["url"] as? String,
                          let host = URL(string: urlString)?.host {
                    domain = host
                } else {
                    reply(nil, error: "cookies.set requires url or domain")
                    return
                }
                let props = [HTTPCookiePropertyKey.domain: domain,
                             HTTPCookiePropertyKey.name: name,
                             HTTPCookiePropertyKey.value: value,
                             HTTPCookiePropertyKey.path: setDetails["path"] as? String ?? "/",
                             HTTPCookiePropertyKey.secure: "1"]
                if let cookie = HTTPCookie(properties: props) {
                    parent.state.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                        reply([:])
                    }
                } else {
                    reply(nil, error: "cookie construction failed")
                }
            case ("notifications", "create"):
                WebExtensionStore.createNotification(args.first as? [String: Any] ?? [:]) { result in
                    reply(result)
                }
            case ("notifications", "clear"):
                let id = args.first as? String ?? ""
                WebExtensionStore.clearNotifications(id.isEmpty ? [] : [id]) { result in
                    reply(result)
                }
            case ("events", "addListener"):
                if let name = args.first as? String, name.hasPrefix("tabs.") {
                    parent.state.hasExtensionTabListeners = true
                    ExtensionEventHub.shared.register(parent.state)
                }
                reply([:])
            case ("runtime", "sendMessageToBackground"):
                Log.userScripts.info("page handler: sendMessageToBackground from \(extID ?? "nil", privacy: .public)")
                // 页面 → background：消息路由（见 PluginBackgroundRuntime）。
                // extID = 发起插件的身份；tabID = 本页面所在标签（sender 用）。
                // 回复目标 = 本页 webview（parent.state.webView，reply 闭包同款）。
                guard let ext = extID.flatMap(UUID.init(uuidString:)) else {
                    reply(nil, error: "no extension identity")
                    return
                }
                let msg = args.first ?? NSNull()
                let sender: [String: Any] = ["tab": parent.tabID.uuidString,
                                             "url": parent.state.webView.url?.absoluteString ?? ""]
                // 路由 id 由 JS 生成上送（args[1]），回包按它找回原 Promise。
                let replyId = (args.count > 1 ? args[1] as? String : nil) ?? UUID().uuidString
                PluginBackgroundRuntime.shared.deliverToBackground(
                    pluginID: ext, message: msg, sender: sender,
                    replyId: replyId, replyWebView: parent.state.webView,
                    replyWorld: world)
                // 回复经 {ns:"runtime", fn:"sendReply"} 异步送达（replyId 路由）。
            case ("runtime", "sendReply"):
                // onMessage 的回复回投（页面 ↔ background 双向共用此通道）。
                let parts = (args.first as? [Any]) ?? []
                let replyId = parts.count > 0 ? String(describing: parts[0]) : ""
                let envelope = parts.count > 1 ? (parts[1] as? [String: Any]) ?? [:] : [:]
                PluginBackgroundRuntime.shared.deliverReply(
                    replyId: replyId,
                    ok: (envelope["ok"] as? Bool) == true,
                    reply: envelope["reply"],
                    noListener: (envelope["noListener"] as? Bool) == true)
                // 该 handler 无 reply 语义（不是 rpc 请求）。
            case ("port", "connect"):
                // 页面端发起长连接：登记端口（含本页 content-script world，
                // background 回包按它求值）并通知 background 页 onConnect。
                guard let portPlugin = extID.flatMap(UUID.init(uuidString:)),
                      let portId = args.first as? String else {
                    reply(nil, error: "port.connect requires extension identity")
                    return
                }
                PluginBackgroundRuntime.shared.openPort(
                    portId: portId, name: (args.count > 1 ? args[1] as? String : nil) ?? "",
                    pluginID: portPlugin,
                    pageWebView: parent.state.webView, pageWorld: world)
                reply([:])
            case ("port", "postMessage"):
                guard let portId = args.first as? String else {
                    reply(nil, error: "port.postMessage requires portId")
                    return
                }
                PluginBackgroundRuntime.shared.portMessage(
                    portId: portId, from: parent.state.webView,
                    payload: args.count > 1 ? args[1] : NSNull())
                reply([:])
            case ("port", "disconnect"):
                if let portId = args.first as? String {
                    PluginBackgroundRuntime.shared.closePort(
                        portId: portId, from: parent.state.webView)
                }
                reply([:])
            default:
                reply(nil, error: "unknown \(ns).\(fn)")
            }
        }

        /// 把这个标签页登记进调试面板的作用域菜单。
        ///
        /// 导航回调（didStart/didFinish）也会登记，但**后台/挂起的标签页拿不到
        /// 导航回调**（挂起时 `navigationDelegate` 被置空，见 TabManager），
        /// 于是"桥在后台标签页里跑了一页"这种情形下菜单里就没有它。消息本身
        /// 一定会到（消息处理器与导航代理无关），所以每条消息也顺手登记一次。
        private func noteTabInDevTools() {
            parent.devToolsStore.noteTab(
                id: parent.tabID,
                title: parent.state.webView.title,
                url: parent.state.webView.url?.absoluteString
            )
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "desireExt" {
                // Isolated-world WebExtension RPC (see extensionWorld).
                // per-plugin world 的消息同样进这条路径（world 由 ext 推导）。
                let world: WKContentWorld
                if let ext = (message.body as? [String: Any])?["ext"] as? String,
                   let uuid = UUID(uuidString: ext) {
                    world = WebView.pluginWorld(uuid)
                } else {
                    world = WebView.extensionWorld
                }
                handleExtensionMessage(message.body, world: world)
            } else if message.name == "otpDetect", let dict = message.body as? [String: String] {
                parent.state.pendingOTPHint = dict["field"] ?? "verification code"
            } else if message.name == "audioState", let playing = message.body as? Bool {
                parent.state.isPlayingAudio = playing
            } else if message.name == "netEntry", let dict = message.body as? [String: Any] {
                noteTabInDevTools()
                parent.devToolsStore.applyNetworkEvent(dict, tabID: parent.tabID)
                // webRequest.onBeforeRequest（MV3 观察语义）：请求 start 一发。
                if (dict["phase"] as? String) == "start" {
                    var details: [String: Any] = [
                        "url": dict["url"] as? String ?? "",
                        "tabId": parent.tabID.uuidString,
                        "frameId": 0,
                    ]
                    if let resourceType = dict["resourceType"] as? String {
                        details["type"] = resourceType
                    }
                    if let method = dict["method"] as? String {
                        details["method"] = method
                    }
                    PluginBackgroundRuntime.shared.fireWebRequest(details: details)
                }
            } else if message.name == "devConsole", let dict = message.body as? [String: Any],
                      let levelStr = dict["level"] as? String,
                      let msgText = dict["message"] as? String {
                let level = ConsoleMessage.Level(rawValue: levelStr) ?? .log
                let url = dict["url"] as? String
                let line = dict["line"] as? Int
                let column = dict["column"] as? Int
                noteTabInDevTools()
                parent.devToolsStore.addConsoleMessage(
                    level: level,
                    message: msgText,
                    url: url,
                    line: line,
                    column: column,
                    tabID: parent.tabID,
                    parts: ConsoleMessage.parseParts(dict["parts"])
                )
            } else if message.name == "passwordDetect", let dict = message.body as? [String: String],
                       let usernameName = dict["username"],
                       let host = parent.state.webView.url?.host {
                let entries = parent.passwordStore.find(domain: host)
                guard !entries.isEmpty else { return }
                // 秘密进 JS 字符串字面量统一走 JSString.literal（旧两段式
                // 转义漏 \n/\r/\u2028——密码含这些字符时整段注入即语法错）。
                let username = JSString.literal(entries[0].username)
                let password = JSString.literal(entries[0].password)
                let nameLiteral = JSString.literal(usernameName)
                let js = """
                (function() {
                    var f = document.querySelector('input[type=password]').closest('form');
                    if (!f) return;
                    var nameLit = \(nameLiteral);
                    var u = f.querySelector('input[name="' + nameLit + '"], input[id="' + nameLit + '"], input[type=text], input[type=email]');
                    if (u) u.value = \(username);
                    var p = f.querySelector('input[type=password]');
                    if (p) p.value = \(password);
                })();
                """
                parent.state.webView.evaluateJavaScript(js, completionHandler: nil)
            } else if message.name == "passwordSave", let dict = message.body as? [String: String],
                       let username = dict["username"], let password = dict["password"],
                       !username.isEmpty, !password.isEmpty {
                // 域名 = 提交**发起页**的 origin（脚本随消息带来）。submit 后
                // 导航立刻开始，此刻 webView.url 多半已是新页——用它会记错域
                // （跨域跳转/SSO 回跳都踩）。旧会话的脚本没带 origin 才回落。
                let host = URL(string: dict["origin"] ?? "")?.host
                    ?? parent.state.webView.url?.host
                guard let host else { return }
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
                parent.state.isPickingElement = false
                switch parent.state.elementPickIntent {
                case .devTools:
                    // 采集完整元素信息填进 Element 页签。
                    Task { [store = parent.devToolsStore, wv = parent.state.webView] in
                        await store.inspectElement(selector: selector, in: wv)
                    }
                    // P1-4：用完还原默认意图——否则之后工具栏的"元素屏蔽"
                    // 拾取被永远劫持进 DevTools 分支。
                    parent.state.elementPickIntent = .block
                case .ai:
                    if let aiHandler = parent.state.onAIElementPicked {
                        parent.state.webView.evaluateJavaScript("""
                        (function() {
                            var el = document.querySelector(\(JSString.literal(selector)));
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
                case .block:
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
            // 只清这个标签页的日志：导航的是它，别的标签页的日志不该被顺手抹掉。
            if parent.devToolsStore.clearConsoleOnNavigate {
                parent.devToolsStore.clearConsole(tabID: parent.tabID)
            }
            // 让调试面板的作用域菜单尽早有这个标签页（此时标题还没拿到，
            // 先记 URL，didFinish 再补标题）。
            parent.devToolsStore.noteTab(id: parent.tabID, url: webView.url?.absoluteString)
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
                    // ① 会话级例外：用户本会话点过"仍然继续"的主机不再询问。
                    // 一次页面加载会对同一主机挑战多次（主框架+子资源+重定向），
                    // 没有记忆就是"疯狂弹窗"（本地自签名站实测）。
                    if ServerTrustExceptions.shared.isGranted(host) {
                        completionHandler(.useCredential, URLCredential(trust: serverTrust))
                        return
                    }
                    // ② 同主机的决策窗已在展示 → 本挑战排队，等第一次的决定
                    //    统一放行/取消。
                    if ServerTrustExceptions.shared.claimPresentation(host) {
                        ServerTrustExceptions.shared.queue(
                            host: host, trust: serverTrust,
                            completionHandler: { disp, cred in
                                completionHandler(disp, cred)
                            })
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Invalid Certificate")
                    let errDesc = error?.localizedDescription ?? String(localized: "Unknown Error")
                    alert.informativeText = String(localized: "The certificate for \(host) is not trusted.\n\n\(errDesc)")
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: String(localized: "Continue Anyway"))
                    alert.addButton(withTitle: String(localized: "Cancel"))
                    // PERF-6：sheet 而非 runModal（runModal 冻结整个 app）。
                    // 无窗口（离屏 webview）直接取消——不弹 app 模态。
                    guard let window = webView.window else {
                        ServerTrustExceptions.shared.deny(host)
                        completionHandler(.cancelAuthenticationChallenge, nil)
                        return
                    }
                    alert.beginSheetModal(for: window) { response in
                        if response == .alertFirstButtonReturn {
                            ServerTrustExceptions.shared.grant(host)
                            completionHandler(.useCredential, URLCredential(trust: serverTrust))
                        } else {
                            ServerTrustExceptions.shared.deny(host)
                            completionHandler(.cancelAuthenticationChallenge, nil)
                        }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Response headers arrived — the watchdog did its job.
            disarmLoadTimeout()
            // 广告规则可能刚被改过（本地覆盖文件 / 远程包）：把页面里旧代数的
            // 隐藏规则换成本次解析出来的。user script 是 webview 创建时定格的，
            // 只有这条导航路径能把新规则送进已打开的标签页（同代则空操作）。
            if let blocker = parent.state.videoAdBlocker {
                if blocker.isEnabled {
                    webView.evaluateJavaScript(
                        VideoAdRulesStore.shared.cssInstallScript(replaceStale: true),
                        completionHandler: nil
                    )
                } else {
                    // P1-14：关闭开关后，已开标签的隐藏 CSS 要反向移除——
                    // 否则旧标签永远继续拦截（冻结脚本无移除路径）。
                    webView.evaluateJavaScript(
                        "(function(){ var s = document.getElementById('desire-video-ad-css'); if (s) s.remove(); })()",
                        completionHandler: nil
                    )
                }
            }
            // New page — the sniffed media list belongs to the old one.
            parent.state.detectedMedia.removeAll()
            // 选区 AI 条同属旧页（选区/坐标已不存在）——不清会一直悬在
            // 新页面上（P2：selectionAI 不随导航清除）。
            parent.state.selectionAI = nil
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
                // 调试面板的作用域菜单要显示标题（KVO 的标题晚到，用 live title）。
                parent.devToolsStore.noteTab(
                    id: parent.tabID,
                    title: webView.title ?? parent.state.pageTitle,
                    url: url.absoluteString
                )
                BridgeEventBus.shared.publish("pageReady", [
                    "url": url.absoluteString,
                    // pageTitle KVO lands later — prefer the live title.
                    "title": webView.title ?? parent.state.pageTitle,
                ])

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
                        s.textContent = \(JSString.literal(css));
                        document.head.appendChild(s);
                    })();
                    """, completionHandler: nil)
                }
                // R2-10：xpath 规则合并为一个脚本一次注入——此前每条规则单独
                // 一次 evaluateJavaScript（规则多时成倍占用 WebKit 串行队列）。
                if !xpathRules.isEmpty {
                    let steps = xpathRules.map { xpath -> String in
                        return """
                        try {
                            var el = document.evaluate(\(JSString.literal(xpath)), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
                            if (el) el.style.display = 'none';
                        } catch(e) {}
                        """
                    }.joined(separator: "\n")
                    webView.evaluateJavaScript(steps, completionHandler: nil)
                }
            }
            if parent.formAutofillStore.isConfigured {
                webView.evaluateJavaScript(parent.formAutofillStore.fillScript, completionHandler: nil)
            }
            // 页面批注恢复（0.3.7）：按 URL 文本锚定重新包裹高亮。
            // R2-13：首见 URL 的读盘（DiskStore.load 同步 IO）挪后台任务，
            // 读完再跳回主线程注入——不再占 didFinish 关键路径。
            if let url = webView.url?.absoluteString {
                let store = AnnotationStore.shared
                Task { @MainActor in
                    let highlights = await store.highlightsInBackground(for: url)
                        .map { ["text": $0.text, "colorIndex": $0.colorIndex] }
                    guard !highlights.isEmpty,
                          let data = try? JSONSerialization.data(withJSONObject: highlights),
                          let json = String(data: data, encoding: .utf8) else { return }
                    _ = try? await webView.evaluateJavaScript(
                        "__desireRestoreHighlights(\(json))")
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
            // 用户引发的取消（goBack/goForward/新导航打断旧加载 = -999）不是
            // 页面错误——写入 lastError 会让错误页盖住回退后的目标页（用户实测
            // "回退经常触发失败页"）。真正的失败由 didFailProvisionalNavigation
            // 与看门狗上报。raw-code 兜底：部分构建 URLError.code 不归一。
            if (error as NSError).code == NSURLErrorCancelled { return }
            // 下载转换（didBecome download 已置 suppress）收尾时的
            // frame-load-interrupted 同样不是错误——不置 lastError。
            if suppressNextFailError {
                suppressNextFailError = false
                return
            }
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
                runBeforeUnloadGuard(webView: webView) { [weak self] allowed in
                    // P1-1：这条 early-return 曾把底部的 armLoadTimeout 闷死
                    // （仅剩 formResubmitted 可达）——挂起的 TCP 永久白页。
                    // 放行时补 arm。
                    if allowed, let self {
                        self.armLoadTimeout(for: url)
                    }
                    decisionHandler(allowed ? .allow : .cancel)
                }
                return
            }

            // **文件链接当场处理**（衔接正解）：链接本身就是文件时按类型分流，
            // 取消导航、页面平滑留在原地——完全不进入"导航→转下载→失败"的
            // 中间态（此前靠 suppress 静默失败是补丁；白名单猜不全也是错，
            // 无扩展名的文件仍由 navigationResponse 的 mime 兜底转下载）。
            //   · 归档/安装类 → 直接进下载面板（进度/暂停/恢复齐全）；
            //   · PDF → 内建查看器（presentPDFViewer 下载到临时文件）；
            //   · 音视频/图片 → 让 WebKit 播/渲染（allow，不改）。
            if navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.navigationType == .linkActivated
                   || navigationAction.navigationType == .other,
               let kind = Self.classifyFileLink(url) {
                switch kind {
                case .download:
                    parent.downloadStore.startURLSessionDownload(
                        sourceURL: url,
                        filename: url.lastPathComponent,
                        isPrivate: parent.state.isIncognito)
                case .pdfViewer:
                    parent.state.presentPDFViewer(
                        for: url, suggestedName: url.lastPathComponent)
                }
                decisionHandler(.cancel)
                return
            }

            // **iframe breakout 拦截**（视频站防跳转）：子框架里的脚本试图把
            // **主框架**导航到第三方域（window.top.location = …）——正片播放器
            // 被广告/验证中间页顶掉，用户看到的是"换 server 后触发验证、播放失败"。
            // 判据：发起 frame 非主框架 + 目标是主框架 + 目标域与当前页域无父子关系。
            // 放行：用户直接点击链接（linkActivated 会开新页走别的路径）。
            if navigationAction.sourceFrame.isMainFrame == false,
               navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.navigationType != .linkActivated,
               let currentHost = webView.url?.host,
               let targetHost = url.host,
               currentHost != targetHost,
               !currentHost.hasSuffix("." + targetHost),
               !targetHost.hasSuffix("." + currentHost) {
                Log.app.info("iframe breakout blocked: \(targetHost, privacy: .public)")
                decisionHandler(.cancel)
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
                    resourceType: resourceType,
                    tabID: parent.tabID
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
            // 内建 PDF 查看器（对齐 Safari）：WKWebView 不渲染 application/pdf
            // （实测主框架导航落白页）——拦下、下载临时文件、PDFKit 展示。
            if navigationResponse.isForMainFrame,
               navigationResponse.response.mimeType == "application/pdf",
               let url = navigationResponse.response.url {
                parent.state.presentPDFViewer(for: url, suggestedName:
                    navigationResponse.response.suggestedFilename ?? url.lastPathComponent)
                decisionHandler(.cancel)
                return
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
            if suppressNextFailError,
               (error as? URLError)?.code == .cancelled
                   || (error as NSError).domain == "WebKitErrorDomain" {
                // -999（取消）或 WKError 域（frame load interrupted——下载转换
                // 的收尾形态）都不是页面错误。
                suppressNextFailError = false
                parent.isLoading = false
                return
            }
            // goBack/goForward/新导航打断引发的取消（-999）同样不是页面错误——
            // 部分构建下 URLError.code 不归一为 .cancelled，按原始 code 兜底。
            if (error as NSError).code == NSURLErrorCancelled { parent.isLoading = false; return }
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
            // PERF-6：sheet 异步 + 无窗口兜底拒绝（后台页面不弹 app 模态）。
            guard let window = webView.window else {
                decisionHandler(.deny)
                return
            }
            alert.beginSheetModal(for: window) { response in
                let granted = response == .alertFirstButtonReturn
                if checkbox.state == .on {
                    self.parent.permissionStore.set(host: host, type: pType, decision: granted ? .allow : .deny)
                }
                decisionHandler(granted ? .grant : .deny)
            }
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
            // PERF-6：sheet 异步 + 无窗口兜底拒绝（后台页面不弹 app 模态）。
            guard let window = webView.window else {
                decisionHandler(.deny)
                return
            }
            alert.beginSheetModal(for: window) { response in
                let granted = response == .alertFirstButtonReturn
                if checkbox.state == .on {
                    self.parent.permissionStore.set(host: host, type: .geolocation, decision: granted ? .allow : .deny)
                }
                decisionHandler(granted ? .grant : .deny)
            }
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
            // PERF-6：sheet 异步；无窗口兜底取消。
            guard let window = webView.window else {
                completionHandler(nil)
                return
            }
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            // PERF-6：sheet 异步等待；无窗口（后台页）直接当已确认返回。
            guard let window = webView.window else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                alert.beginSheetModal(for: window) { _ in continuation.resume() }
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = webView.url?.host ?? ""
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard let window = webView.window else { return false }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
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
            guard let window = webView.window else { return nil }
            let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
            guard confirmed else { return nil }
            return textField.stringValue
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            // 主框架导航转下载时 WebKit 会以 frame-load-interrupted 收尾这次
            // 导航——那是下载的正常形态，不是页面错误。置 suppress 让随后的
            // didFail(Provisional) 静默（此前错误页盖住当前页，用户实测
            // GitHub release 下载"页面变成无法加载"而文件实际已下完）。
            suppressNextFailError = true
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
