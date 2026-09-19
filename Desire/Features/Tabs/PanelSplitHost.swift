import AppKit
import SwiftUI
import WebKit

/// AppKit 分屏内核（0.3.9 定案，外部会诊方向）：
/// 主 webview | 分屏右栏 | Agent 面板 | DevTools 面板 + 分隔条整块下沉为
/// 一个 NSViewRepresentable。拖动 = PaneDividerView（纯 AppKit
/// mouseDown/Dragged）改容器宽度 → layout() 直接 setFrame——全程不经
/// SwiftUI body 重算，WKWebView 的 resize 走最直接的 AppKit 路径
/// （与 Safari/NSSplitView 同构）。SwiftUI 只保留上层 chrome（工具栏/
/// 标签栏/浮层），宽度只在拖动结束时一次性回写持久化。
struct PanelSplitHost: NSViewRepresentable {
    @ObservedObject var tab: Tab
    let content: ContentView
    let actions: BrowsingActions
    let agentVisible: Bool
    let devVisible: Bool
    let overviewVisible: Bool
    /// 拖动结束回调（partner/agent/devtools 最终宽度 → SwiftUI 持久层）。
    var onWidthsCommitted: ((CGFloat, CGFloat, CGFloat) -> Void)?
    /// 初始宽度种子（仅首次装配采用，之后容器自持）。
    var seedWidths: (partner: CGFloat, agent: CGFloat, devtools: CGFloat)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = PanelContainerView()
        container.seeds = seedWidths
        let coord = context.coordinator
        container.onWidthsCommitted = { p, a, d in
            coord.parent.onWidthsCommitted?(p, a, d)
        }
        context.coordinator.container = container
        context.coordinator.sync(force: true)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        guard let container = nsView as? PanelContainerView else { return }
        context.coordinator.container = container
        context.coordinator.sync(force: false)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - Coordinator：槽位装配 + 签名去重

    final class Coordinator {
        var parent: PanelSplitHost
        weak var container: PanelContainerView?
        /// 主/partner webview 的 delegate 宿主（与 SwiftUI representable
        /// 路径同一套 attach/detach，行为完全一致）。
        private var mainCoord: WebView.Coordinator?
        private var partnerCoord: WebView.Coordinator?
        private var signature: Signature?

        init(parent: PanelSplitHost) {
            self.parent = parent
        }

        /// 决定"要不要重装配"的最小签名——progress/hover 等高频发布
        /// 落到这里全部短路（updateNSView 廉价 no-op）。
        private struct Signature: Equatable {
            var tabID: UUID
            var branch: String        // overview/reading/loading-reading/newtab/suspended/web
            var partnerID: UUID?
            var agent: Bool
            var dev: Bool
            var responsive: CGSize?
        }

        private func currentSignature() -> Signature {
            let t = parent.tab
            let branch: String
            if parent.overviewVisible { branch = "overview" }
            else if t.browser.isReadingMode { branch = t.browser.isReaderLoading ? "reading-loading" : "reading" }
            else if t.isOnNewTabPage { branch = "newtab" }
            else if t.isSuspended { branch = "suspended" }
            else { branch = "web" }
            return Signature(
                tabID: t.id,
                branch: branch,
                partnerID: parent.content.tabManager.splitPartner?.id,
                agent: parent.agentVisible,
                dev: parent.devVisible,
                responsive: t.responsiveConfig.isEnabled ? t.responsiveConfig.effectiveSize : nil)
        }

        func sync(force: Bool) {
            guard let container else { return }
            let sig = currentSignature()
            if !force, sig == signature { return }
            signature = sig

            let content = parent.content
            let tab = parent.tab

            // ---- 主槽 ----
            if sig.branch == "overview" {
                // 概览重挂所有 webview：主槽让位（delegate 由概览侧接管）。
                detachMain()
                container.setMainContent(nil)
            } else if sig.branch.hasPrefix("reading") {
                detachMain()
                container.setMainContent(.hosting(AnyView(
                    ReaderView(
                        title: tab.browser.readerTitle,
                        contentHTML: tab.browser.readerContent,
                        isLoading: tab.browser.isReaderLoading,
                        onClose: {
                            tab.browser.isReadingMode = false
                            tab.browser.isReaderLoading = false
                        })
                )))
            } else if sig.branch == "newtab" {
                detachMain()
                container.setMainContent(.hosting(AnyView(
                    NewTabPage(
                        store: content.quickDialStore,
                        urlString: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }),
                        onNavigate: { [parent] input in parent.actions.navigateToURL(input, for: tab) },
                        suggestionModel: content.newTabSuggestionModel,
                        bookmarkStore: content.bookmarkStore,
                        historyStore: content.historyStore,
                        settings: content.settings)
                )))
            } else if sig.branch == "suspended" {
                detachMain()
                container.setMainContent(.hosting(AnyView(SuspendedTabView(tab: tab))))
            } else {
                // 真 webview：与旧 SwiftUI 路径同一工厂取 props，同一套挂接。
                let representable = content.makeWebView(for: tab)
                if tab.browser.webView !== container.mainWebView {
                    detachMain()
                    let coord = WebView.Coordinator(representable)
                    WebView.attachShared(tab.browser.webView, parent: representable, coordinator: coord)
                    mainCoord = coord
                } else if let coord = mainCoord {
                    coord.parent = representable
                }
                container.setMainContent(.webView(tab.browser.webView))
                container.responsiveMainSize = sig.responsive
            }

            // ---- 分屏右栏 ----
            if let partner = content.tabManager.splitPartner, partner.id != tab.id {
                let representable = content.makeWebView(for: partner)
                if partner.browser.webView !== container.partnerWebView {
                    detachPartner()
                    let coord = WebView.Coordinator(representable)
                    WebView.attachShared(partner.browser.webView, parent: representable, coordinator: coord)
                    partnerCoord = coord
                } else if let coord = partnerCoord {
                    coord.parent = representable
                }
                container.setPartner(webView: partner.browser.webView,
                                     title: partner.displayTitle,
                                     onClose: { content.tabManager.setSplitPartner(at: nil) })
            } else {
                detachPartner()
                container.setPartner(webView: nil, title: "", onClose: nil)
            }

            // ---- Agent / DevTools（NSHostingView，store 自驱动更新）----
            container.setAgent(visible: sig.agent, root: AnyView(
                AgentPanel(store: content.aiSession, conversationStore: content.conversationStore)
                    .onAppear {
                        Task { @MainActor in
                            content.aiSession.resumeLatestConversation()
                        }
                    }
            ))
            container.setDevtools(visible: sig.dev, root: AnyView(
                DevToolsPanel(
                    store: content.devToolsStore,
                    tab: tab,
                    onStartElementPicker: {
                        tab.browser.isPickingElement = true
                        tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                    },
                    onClose: { content.toggleDevTools() })
            ))
            container.needsLayout = true
        }

        private func detachMain() {
            if let wv = container?.mainWebView, let coord = mainCoord {
                WebView.detachShared(wv, coordinator: coord)
            }
            mainCoord = nil
        }

        private func detachPartner() {
            if let wv = container?.partnerWebView, let coord = partnerCoord {
                WebView.detachShared(wv, coordinator: coord)
            }
            partnerCoord = nil
        }

        func teardown() {
            detachMain()
            detachPartner()
            container?.clearAll()
        }
    }
}

// MARK: - 容器（帧布局）

/// 手写 frame 布局（无 AutoLayout 约束求解——拖动路径就是 layout() 里
/// 几次 setFrame，最低开销）。右→左：DevTools | Agent | 分屏右栏，主槽
/// 吃剩余宽度（min 240）。
final class PanelContainerView: NSView {
    enum SlotContent {
        case webView(BrowserWKWebView)
        case hosting(AnyView)
    }

    // 槽位
    private(set) var mainWebView: BrowserWKWebView?
    private(set) var partnerWebView: BrowserWKWebView?
    private var mainHost: NSHostingView<AnyView>?
    private var partnerSlot = NSView()
    private var partnerHeaderHost: NSHostingView<AnyView>?
    private var agentHost: NSHostingView<AnyView>?
    private var devHost: NSHostingView<AnyView>?
    private let dividerPartner = PaneDividerView()
    private let dividerAgent = PaneDividerView()
    private let dividerDev = PaneDividerView()

    // 宽度（AppKit 自持；拖动只改这里）
    var partnerWidth: CGFloat = 420
    var agentWidth: CGFloat = 320
    var devWidth: CGFloat = 420
    var seeds: (partner: CGFloat, agent: CGFloat, devtools: CGFloat)?
    var responsiveMainSize: CGSize?
    var onWidthsCommitted: ((CGFloat, CGFloat, CGFloat) -> Void)?
    private var partnerClose: (() -> Void)?
    private var seeded = false

    private struct Box {
        let view: NSView
        var width: CGFloat
    }

    init() {
        super.init(frame: .zero)
        for d in [dividerPartner, dividerAgent, dividerDev] {
            addSubview(d)
        }
        dPMC()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func dPMC() {} // 占位：防止误删分隔条注册

    // MARK: 槽位装配

    func setMainContent(_ content: SlotContent?) {
        mainWebView?.removeFromSuperview()
        mainWebView = nil
        mainHost?.removeFromSuperview()
        mainHost = nil
        responsiveMainSize = nil
        switch content {
        case .webView(let wv):
            mainWebView = wv
            addSubview(wv)
        case .hosting(let view):
            let host = NSHostingView(rootView: view)
            mainHost = host
            addSubview(host)
        case nil:
            break
        }
        needsLayout = true
    }

    func setPartner(webView: BrowserWKWebView?, title: String, onClose: (() -> Void)?) {
        guard let webView else {
            partnerWebView?.removeFromSuperview()
            partnerWebView = nil
            partnerHeaderHost?.removeFromSuperview()
            partnerHeaderHost = nil
            partnerClose = nil
            needsLayout = true
            return
        }
        if partnerWebView !== webView {
            partnerWebView?.removeFromSuperview()
            partnerWebView = webView
            addSubview(webView)
        }
        partnerClose = onClose
        if partnerHeaderHost == nil {
            let header = NSHostingView(rootView: AnyView(EmptyView()))
            partnerHeaderHost = header
            partnerSlot.addSubview(header)
            addSubview(partnerSlot)
        }
        partnerHeaderHost?.rootView = AnyView(PartnerHeader(title: title, onClose: { [weak self] in
            self?.partnerClose?()
        }))
        needsLayout = true
    }

    func setAgent(visible: Bool, root: AnyView) {
        setHost(&agentHost, visible: visible, root: root)
    }

    func setDevtools(visible: Bool, root: AnyView) {
        setHost(&devHost, visible: visible, root: root)
    }

    private func setHost(_ slot: inout NSHostingView<AnyView>?, visible: Bool, root: AnyView) {
        if visible {
            if let host = slot {
                addSubview(host)   // 幂等（重复 add 会先移除）
            } else {
                let host = NSHostingView(rootView: root)
                slot = host
                addSubview(host)
            }
        } else {
            slot?.removeFromSuperview()
        }
        needsLayout = true
    }

    func clearAll() {
        setMainContent(nil)
        setPartner(webView: nil, title: "", onClose: nil)
        for host in [agentHost, devHost] { host?.removeFromSuperview() }
        agentHost = nil
        devHost = nil
    }

    // MARK: 布局（拖动热路径：右→左定位，几次 setFrame）

    override func layout() {
        super.layout()
        if !seeded, let seeds {
            partnerWidth = seeds.partner
            agentWidth = seeds.agent
            devWidth = seeds.devtools
            seeded = true
        }
        let bounds = self.bounds
        guard bounds.width > 10 else { return }

        // 右侧面板栈（右→左），每块 = divider(5) + 面板
        var x = bounds.maxX
        var boxes: [Box] = []

        if devHost != nil {
            devWidth = min(devWidth, bounds.width - 240)
            x -= 5; dividerDev.frame = NSRect(x: x, y: 0, width: 5, height: bounds.height)
            devWidth = max(300, devWidth)
            x -= devWidth
            boxes.append(Box(view: devHost!, width: devWidth))
        } else { dividerDev.removeFromSuperview() }

        if agentHost != nil {
            x -= 5; dividerAgent.frame = NSRect(x: x, y: 0, width: 5, height: bounds.height)
            agentWidth = max(260, min(agentWidth, max(260, bounds.width - 240 - (devHost != nil ? devWidth + 5 : 0))))
            x -= agentWidth
            boxes.append(Box(view: agentHost!, width: agentWidth))
        } else { dividerAgent.removeFromSuperview() }

        if partnerWebView != nil {
            x -= 5; dividerPartner.frame = NSRect(x: x, y: 0, width: 5, height: bounds.height)
            partnerWidth = max(220, min(partnerWidth, max(220, x - bounds.minX - 240)))
            x -= partnerWidth
            partnerSlot.frame = NSRect(x: x, y: 0, width: partnerWidth, height: bounds.height)
            layoutPartnerSlot()
        } else { dividerPartner.removeFromSuperview() }

        // 主槽吃剩余
        let mainW = max(0, x - bounds.minX)
        if let wv = mainWebView {
            if let rs = responsiveMainSize {
                // 响应式：设备尺寸居中（与旧 SwiftUI 几何一致）。
                let w = min(rs.width, mainW - 40)
                let h = min(rs.height, bounds.height - 40)
                wv.frame = NSRect(x: bounds.minX + (mainW - w) / 2,
                                  y: (bounds.height - h) / 2, width: w, height: h)
            } else {
                wv.frame = NSRect(x: bounds.minX, y: 0, width: mainW, height: bounds.height)
            }
        }
        mainHost?.frame = NSRect(x: bounds.minX, y: 0, width: mainW, height: bounds.height)

        for box in boxes {
            box.view.frame = NSRect(x: x, y: 0, width: box.width, height: bounds.height)
            x += box.width + 5
        }
    }

    private func layoutPartnerSlot() {
        let f = partnerSlot.bounds
        partnerHeaderHost?.frame = NSRect(x: 0, y: f.height - 24, width: f.width, height: 24)
        partnerWebView?.frame = NSRect(x: 0, y: 0, width: f.width, height: max(0, f.height - 25))
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsLayout = true
    }

    /// 分隔条回调：改宽 → 重布局（一次 mouseDragged 一次 layout）。
    func paneDivider(_ divider: PaneDividerView, didDragBy delta: CGFloat) {
        if divider === dividerPartner { partnerWidth = max(220, partnerWidth + delta) }
        if divider === dividerAgent { agentWidth = max(260, agentWidth + delta) }
        if divider === dividerDev { devWidth = max(300, devWidth + delta) }
        needsLayout = true
    }

    func paneDividerDidEndDrag() {
        onWidthsCommitted?(partnerWidth, agentWidth, devWidth)
    }
}

// MARK: - 分隔条（纯 AppKit 拖动）

final class PaneDividerView: NSView {
    var acceptsFirstMouseFlag: Bool { true }
    private var dragStartWidth: CGFloat = 0
    private var trackingTag: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tag = trackingTag { removeTrackingArea(tag) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingTag = area
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = (isHovering || dragStartWidth > 0)
            ? NSColor.controlAccentColor.withAlphaComponent(0.45)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.22)
        color.setFill()
        bounds.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    private var mouseDownWindowX: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        guard let container = superview as? PanelContainerView else { return }
        dragStartWidth = container.width(of: self)
        mouseDownWindowX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let container = superview as? PanelContainerView, dragStartWidth > 0 else { return }
        // 面板在右：光标左移（delta<0）= 面板加宽。
        let delta = event.locationInWindow.x - mouseDownWindowX
        container.paneDivider(self, setWidthAbsolute: dragStartWidth - delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard let container = superview as? PanelContainerView else { return }
        dragStartWidth = 0
        container.paneDividerDidEndDrag()
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
}

// MARK: - 容器辅助

extension PanelContainerView {
    func paneDivider(_ divider: PaneDividerView, setWidthAbsolute value: CGFloat) {
        if divider === dividerPartner { partnerWidth = max(220, value) }
        if divider === dividerAgent { agentWidth = max(260, value) }
        if divider === dividerDev { devWidth = max(300, value) }
        needsLayout = true
    }

    func width(of divider: PaneDividerView) -> CGFloat {
        if divider === dividerPartner { return partnerWidth }
        if divider === dividerAgent { return agentWidth }
        if divider === dividerDev { return devWidth }
        return 0
    }
}

// MARK: - 分屏右栏迷你标题（SwiftUI 内容经 NSHostingView 呈现）

private struct PartnerHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "rectangle.split.1x2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Leave Split View"))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }
}
