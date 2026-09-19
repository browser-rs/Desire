import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - SelectedTabContent

/// Renders everything that must live-update with the selected tab's per-page
/// state (estimatedProgress, isLoading, reader mode, error overlay, responsive
/// config, hovered link, ...).
///
/// Split out of `ContentView.body` so that `Tab.browser.objectWillChange` —
/// which fires on every progress tick, hover, and load-state flip — only
/// re-evaluates *this* view, not the whole `ContentView` (which owns the tab
/// strip, sheets, toasts, and keyboard-shortcut overlays). `Tab` is observed
/// directly here via `@ObservedObject`. Before this split, `TabManager`
/// forwarded every tab's `objectWillChange` up to itself, invalidating the
/// entire app UI on each tick.
///
/// Reads `ContentView`'s stores and state through the `content` reference
/// (those members are internal for that reason) and the browsing-actions
/// coordinator through `actions`.
struct SelectedTabContent: View {
    @ObservedObject var tab: Tab
    let content: ContentView
    /// Direct reference to the browsing-actions coordinator so closures
    /// inside this view call the real object (not a stale struct copy of
    /// ContentView whose @StateObject may not be managed by SwiftUI here).
    let actions: BrowsingActions
    /// Panel-visibility flags passed explicitly (not read through `content`)
    /// so SwiftUI correctly re-renders this view when they change.
    let showSidebar: Bool
    @Binding var showAgentPanel: Bool
    let showDevToolsPanel: Bool
    let isFindBarVisible: Bool
    /// Sends an AI prompt (and opens the panel) from the selection bar.
    let onAskAI: (String) -> Void
    /// Draggable panel widths (persisted per-session, not across launches).
    @State private var devToolsWidth: CGFloat = 420
    @State private var agentPanelWidth: CGFloat = 320

    @State private var inspectorWidth: CGFloat = 220
    /// 分屏右栏宽度（0.2.15）——随窗口布局持久性同 devToolsWidth，仅会话内有效。
    @State private var splitPaneWidth: CGFloat = 420

    // MARK: 拖动冻结 + 平台级快照层（0.3.9 终版）
    //
    // 五轮失败复盘（详见 memory/macos26-webkit-constraints）：
    //  ③分支换快照 → 共享 webview 摘挂/重挂 = 拖起/松手两次白闪；
    //  ④SwiftUI .overlay 遮罩 → 被后面的平台视图（webview）盖住，
    //    遮罩从未可见，webview 仍逐帧 resize 逐帧闪（本项目实测坑）；
    //  ⑤drawsBackground=false → 只灭了 AppKit 白底，页面自身背景
    //    仍逐帧异步重画 = 依旧闪。
    // 结论：唯一出路 = 拖动期【冻结真 webview 的 frame】（零 setFrame
    // = 零 WebKit 重排），视觉实时跟随由快照层承担——且快照层必须是
    // 平台视图（NSView + layer.contents），声明在 webview 之后，按
    // 平台视图 z 序规则必然盖在其上（SwiftUI Image 做不到）。
    @State private var dragActive = false
    @State private var dragGeneration = 0
    @State private var frozenMainWidth: CGFloat?
    @State private var frozenPartnerWidth: CGFloat?
    @State private var snapshotMain: NSImage?
    @State private var snapshotPartner: NSImage?
    /// 主栏当前实际宽（GeometryReader 持续回写；拖起时取作冻结值）。
    @State private var liveMainWidth: CGFloat = 0

    private func beginPaneDrag() {
        guard !dragActive else { return }
        dragActive = true
        frozenMainWidth = liveMainWidth > 0 ? liveMainWidth : nil
        frozenPartnerWidth = splitPaneWidth
        dragGeneration += 1
        let gen = dragGeneration
        let mainWV = tab.browser.webView
        let partnerWV = content.tabManager.splitPartner?.browser.webView
        mainWV.takeSnapshot(with: nil) { [self] img, _ in
            Task { @MainActor in
                guard gen == dragGeneration, dragActive else { return }
                snapshotMain = img
            }
        }
        if let partnerWV {
            partnerWV.takeSnapshot(with: nil) { [self] img, _ in
                Task { @MainActor in
                    guard gen == dragGeneration, dragActive else { return }
                    snapshotPartner = img
                }
            }
        }
    }

    private func endPaneDrag() {
        dragGeneration += 1
        dragActive = false
        snapshotMain = nil
        snapshotPartner = nil
        frozenMainWidth = nil
        frozenPartnerWidth = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(tab.browser.estimatedProgress))
                    }
            }
            .frame(height: 2)
            .opacity(tab.isLoading ? 1 : 0)
            .animation(.smooth(duration: 0.15), value: tab.browser.estimatedProgress)
            .animation(.easeInOut(duration: 0.2), value: tab.isLoading)

            // Toolbar spans full width above the content area (matches
            // original ContentView.body layout before SelectedTabContent
            // extraction).
            content.toolbarSection(for: tab)
            content.bookmarksBarSection(for: tab)
            content.noticeBars(for: tab)

            HStack(spacing: 0) {
                if showSidebar {
                    SidebarView(
                        bookmarkStore: content.bookmarkStore,
                        historyStore: content.historyStore,
                        readingListStore: content.readingListStore,
                        onNavigate: { url in actions.navigateToURL(url, for: tab) }
                    )
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 800)
                }

                VStack(spacing: 0) {
                    if tab.responsiveConfig.isEnabled {
                        ResponsiveDesignBar(
                            config: Binding(get: { tab.responsiveConfig }, set: { tab.responsiveConfig = $0 }),
                            responsiveStore: content.responsiveDesignStore,
                            onScreenshot: { actions.captureResponsiveScreenshot(for: tab) },
                            mediaQueries: content.mediaQueries
                        )

                        ResponsiveMQBar(viewportWidth: tab.responsiveConfig.effectiveSize.width) { newWidth in
                            tab.responsiveConfig.selectedPresetID = nil
                            tab.responsiveConfig.customWidth = Int(newWidth)
                        }
                    }

                    if isFindBarVisible {
                        FindBar(
                            findString: content.$findString,
                            findMatchCount: content.findMatchCount,
                            findCurrentIndex: content.findCurrentIndex,
                            isFindFocused: content.$isFindFocused,
                            onFindNext: { content.performFindNext() },
                            onFindPrevious: { content.performFindPrevious() },
                            onHide: { content.hideFindBar() },
                            onFindAll: { content.performFindAll() }
                        )
                    }

                    ZStack(alignment: .topLeading) {
                    Group {
                        if tab.browser.isReadingMode {
                            ReaderView(
                                title: tab.browser.readerTitle,
                                contentHTML: tab.browser.readerContent,
                                isLoading: tab.browser.isReaderLoading,
                                onClose: {
                                    tab.browser.isReadingMode = false
                                    tab.browser.isReaderLoading = false
                                }
                            )
                        } else if tab.isSuspended {
                            SuspendedTabView(tab: tab)
                        } else if tab.isOnNewTabPage {
                            NewTabPage(store: content.quickDialStore, urlString: Binding(
                                get: { tab.urlString },
                                set: { tab.urlString = $0 }
                            ), onNavigate: { input in
                                actions.navigateToURL(input, for: tab)
                            }, suggestionModel: content.newTabSuggestionModel, bookmarkStore: content.bookmarkStore, historyStore: content.historyStore, settings: content.settings)
                        } else if content.showTabOverview {
                            // 标签概览正挂载本标签的 webview——同一 NSView
                            // 不能双宿主，主区让位（概览关闭后自动还原）。
                            Color.clear
                        } else {
                            GeometryReader { geo in
                                let effectiveSize = tab.responsiveConfig.effectiveSize
                                let responsiveW: CGFloat? = tab.responsiveConfig.isEnabled ? min(effectiveSize.width, geo.size.width - 40) : nil
                                let responsiveH: CGFloat? = tab.responsiveConfig.isEnabled ? min(effectiveSize.height, geo.size.height - 40) : nil
                                content.makeWebView(for: tab)
                                    .overlay(alignment: .topLeading) {
                                        // AI bar next to the user's text selection.
                                        if let selection = tab.browser.selectionAI {
                                            SelectionAIBar(
                                                onExplain: {
                                                    onAskAI("请用中文解释以下选中文本的含义，如有术语请一并说明：\n\n\(selection.text)")
                                                    tab.browser.selectionAI = nil
                                                },
                                                onTranslate: {
                                                    onAskAI("将以下内容翻译成中文（若原文已是中文则翻译成英文），只输出译文：\n\n\(selection.text)")
                                                    tab.browser.selectionAI = nil
                                                },
                                                onAsk: {
                                                    content.aiSession.addSelectedTextContext(selection.text)
                                                    showAgentPanel = true
                                                    tab.browser.selectionAI = nil
                                                },
                                                onHighlight: { colorIndex in
                                                    if let url = tab.browser.webView.url?.absoluteString {
                                                        AnnotationStore.shared.add(
                                                            url: url, text: selection.text,
                                                            colorIndex: colorIndex)
                                                    }
                                                    tab.browser.webView.evaluateJavaScript(
                                                        "__desireApplyHighlight(\(colorIndex))",
                                                        completionHandler: nil)
                                                    tab.browser.selectionAI = nil
                                                }
                                            )
                                            .offset(
                                                x: min(max(selection.viewportX * tab.browser.pageZoom, 8), max(geo.size.width - 220, 8)),
                                                y: min(max(selection.viewportY * tab.browser.pageZoom + 10, 8), max(geo.size.height - 40, 8))
                                            )
                                        }
                                    }
                                    .frame(width: responsiveW, height: responsiveH)
                                    // Overlays attach to the DEVICE-SIZED
                                    // frame — attaching after the infinity
                                    // frame left handles/rulers floating in
                                    // the empty space while the viewport sat
                                    // centered.
                                    .overlay {
                                        if tab.responsiveConfig.isEnabled {
                                            DeviceFrameOverlay(config: tab.responsiveConfig, viewportSize: effectiveSize)
                                        }
                                    }
                                    .overlay {
                                        if tab.responsiveConfig.isEnabled,
                                           let error = tab.browser.lastError {
                                            ErrorPageView(error: error, tab: tab)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                    }
                                    .overlay {
                                        if tab.responsiveConfig.isEnabled {
                                            DragHandleOverlay(
                                                config: Binding(get: { tab.responsiveConfig }, set: { tab.responsiveConfig = $0 }),
                                                viewportSize: effectiveSize
                                            )
                                        }
                                    }
                                    .overlay {
                                        if tab.responsiveConfig.isEnabled && tab.responsiveConfig.showRulers {
                                            RulerOverlay(viewportSize: effectiveSize)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background {
                                        if tab.responsiveConfig.isEnabled {
                                            WorkbenchGrid()
                                        }
                                    }
                                    .onChange(of: tab.responsiveConfig.touchSimulationEnabled) { _, enabled in
                                        if enabled {
                                            TouchSimulation.apply(to: tab.browser.webView)
                                        } else {
                                            TouchSimulation.remove(from: tab.browser.webView)
                                        }
                                    }
                                    .onChange(of: tab.responsiveConfig.isEnabled) { _, enabled in
                                        // UA swap + reload: the single funnel so
                                        // every enable/disable entry point behaves
                                        // identically (menu, toolbar, agent tool).
                                        ResponsiveModeApplier.apply(enabled, to: tab)
                                    }
                                    .onChange(of: tab.responsiveConfig.effectiveSize) { _, size in
                                        // Rotate / resize: keep the UA class in
                                        // step without reloading (affects future
                                        // requests only).
                                        if tab.responsiveConfig.isEnabled {
                                            tab.browser.webView.customUserAgent =
                                                ResponsiveModeApplier.userAgent(forViewport: size)
                                        }
                                    }
                                    .onChange(of: geo.size.width) { _, w in
                                        // 拖起冻结用：主栏实时宽度（布局后回写）。
                                        liveMainWidth = w
                                    }
                                    .onAppear { liveMainWidth = geo.size.width }
                                    .onChange(of: tab.responsiveConfig.showMediaQueryInspector) { _, show in
                                        if show {
                                            actions.refreshMediaQueries(for: tab) { content.mediaQueries = $0 }
                                        }
                                    }
                                    .onChange(of: tab.responsiveConfig.effectiveSize) { _, _ in
                                        if tab.responsiveConfig.showMediaQueryInspector {
                                            actions.refreshMediaQueries(for: tab) { content.mediaQueries = $0 }
                                        }
                                    }
                            }
                        }
                    }
                    .id(tab.id)
                    .frame(width: frozenMainWidth, alignment: .topLeading)
                    // 拖动冻结（0.3.9）：真 webview 固定在拖起时宽度（零
                    // setFrame = 零重排）；快照层是平台视图且声明在后，
                    // 按 z 序必然盖在 webview 上，拉伸实时跟随容器。
                    if dragActive, let snap = snapshotMain {
                        SnapshotLayerView(image: snap)
                    }
                    }
                    .clipped()
                    .overlay(alignment: .top) {
                        if content.isUrlFocused {
                            AddressSuggestionsView(
                                model: content.suggestionModel,
                                engineName: content.settings.effectiveEngineName,
                                searchHistoryStore: content.searchHistoryStore,
                                onSelect: { sug in
                                    content.suggestionModel.reset()
                                    content.isUrlFocused = false
                                    actions.navigateToURL(sug.url, for: tab)
                                },
                                onSearchHistorySelect: { query in
                                    content.suggestionModel.reset()
                                    content.isUrlFocused = false
                                    let url = content.settings.searchURLTemplate
                                        + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
                                    actions.navigateToURL(url, for: tab)
                                }
                            )
                            .padding(.horizontal, 12)
                            .padding(.top, 2)
                            .transition(.opacity)
                        }
                    }
                    .overlay {
                        if let error = tab.browser.lastError, !tab.isOnNewTabPage {
                            ErrorPageView(error: error, tab: tab)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let partner = content.tabManager.splitPartner, partner.id != tab.id {
                    // 分屏浏览（0.2.15）：宽度实时跟随；拖起/松手钩子驱动
                    // webview 冻结 + 快照层（见 beginPaneDrag 注释）。
                    DragHookDivider(width: $splitPaneWidth, range: 220...1400,
                                    dragStarted: { beginPaneDrag() },
                                    dragEnded: { endPaneDrag() })
                    SplitPartnerPane(partner: partner, content: content,
                                     frozenWidth: frozenPartnerWidth,
                                     snapshot: dragActive ? snapshotPartner : nil)
                        .frame(width: splitPaneWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if tab.responsiveConfig.isEnabled && tab.responsiveConfig.showMediaQueryInspector {
                    MediaQueryInspector(queries: content.mediaQueries)
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 560)
                }

                if showAgentPanel {
                    DragHookDivider(width: $agentPanelWidth, range: 260...1200,
                                    dragStarted: { beginPaneDrag() },
                                    dragEnded: { endPaneDrag() })
                    // 等值门控：宽度是宿主 @State，拖动每帧重算宿主 body
                    // 会连带重 diff 整个会话面板（Markdown 列表很贵）。
                    // 面板输入稳定 → 跳过；其内部 @ObservedObject 的更新
                    // 不经此路径，照常生效；宽度在门控外每帧应用。
                    StableAgentPanel(content: content).equatable()
                        .frame(width: agentPanelWidth)
                        // Opening the assistant resumes the most recent
                        // conversation instead of a blank panel. Deferred
                        // off the view-update pass: loading publishes
                        // `messages`, and mutating an observed store
                        // synchronously inside onAppear trips
                        // "Publishing changes from within view updates".
                        .onAppear {
                            Task { @MainActor in
                                content.aiSession.resumeLatestConversation()
                            }
                        }
                }

                if showDevToolsPanel {
                    DragHookDivider(width: $devToolsWidth, range: 300...1400,
                                    dragStarted: { beginPaneDrag() },
                                    dragEnded: { endPaneDrag() })
                    StableDevToolsPanel(content: content, tabID: tab.id)
                        .frame(width: devToolsWidth)
                }
            }
            .animation(.layoutSpring, value: content.tabManager.splitPartnerID)

            if content.settings.showLinkPreview, let hoverURL = tab.browser.hoveredLinkURL, !tab.isOnNewTabPage {
                HStack(spacing: 4) {
                    Text(hoverURL)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(.bar)
            }
        }
    }
}




/// AgentPanel 的等值包装（0.3.9 卡顿治理）：恒等比较让宿主拖动期间
/// 的每帧 body 重算跳过整个会话面板的 diff；面板自身的 store 发布
/// 仍会驱动其更新（@ObservedObject 不走父路径）。
private struct StableAgentPanel: View, Equatable {
    let content: ContentView

    static func == (lhs: Self, rhs: Self) -> Bool { true }

    var body: some View {
        AgentPanel(store: content.aiSession, conversationStore: content.conversationStore)
    }
}

/// DevToolsPanel 同理（按 tab 身份比较——切标签需重渲染）。
private struct StableDevToolsPanel: View, Equatable {
    let content: ContentView
    let tabID: UUID

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.tabID == rhs.tabID }

    var body: some View {
        if let tab = content.tabManager.tabs.first(where: { $0.id == tabID }) {
            DevToolsPanel(
                store: content.devToolsStore,
                tab: tab,
                onStartElementPicker: {
                    tab.browser.isPickingElement = true
                    tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                },
                onClose: { content.toggleDevTools() }
            )
        }
    }
}

/// 平台级快照层（0.3.9）：NSView + layer.contents 渲染拉伸快照。
/// 必须是平台视图——SwiftUI Image 的 .overlay 会被后面的 webview 平台
/// 视图盖住（本项目实测）；平台兄弟视图按声明序定 z 序，本视图声明在
/// webview 之后 = 必然在上。
struct SnapshotLayerView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSView {
        let view = SnapshotLayerNSView()
        view.update(image: image)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SnapshotLayerNSView)?.update(image: image)
    }

    final class SnapshotLayerNSView: NSView {
        // 拖动每帧都会走 updateNSView；NSImage→CGImage 是栅格化级重活，
        // 图没变（同一引用）必须直接跳过——否则拖一下每帧白转两次大图。
        private var lastImage: ObjectIdentifier?
        private var cachedCG: CGImage?

        func update(image: NSImage) {
            wantsLayer = true
            let id = ObjectIdentifier(image)
            guard id != lastImage else { return }
            lastImage = id
            cachedCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            if let cachedCG {
                layer?.contents = cachedCG
                layer?.contentsGravity = .resizeAspectFill
                layer?.masksToBounds = true
            }
        }
    }
}

/// 带拖起/松手钩子的分隔条（0.3.9）：宽度语义与 ResizableDivider 完全
/// 相同（基线 + 累计 translation 实时跟随），钩子只驱动冻结/快照机制。
struct DragHookDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let dragStarted: () -> Void
    let dragEnded: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(isDragging || isHovering ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.22))
            .frame(width: 5)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else if !isDragging {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStarted()
                        }
                        if dragStartWidth == nil { dragStartWidth = width }
                        width = (dragStartWidth! - value.translation.width)
                            .clamped(to: range)
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        dragStartWidth = nil
                        isDragging = false
                        dragEnded()
                    }
            )
    }
}

/// 分屏右栏（0.2.15）：并排显示的第二个标签的活动 webview。顶部一条
/// 迷你标题（标签标题 + 退出分屏）让右栏看起来是个成型的面板而不是
/// 裸贴的第二个网页。工具栏/查找条/阅读模式/响应式模式是选中标签专属
/// 机制，不复制到右栏；新标签页对象仍用 NewTabPage（webview 此时是
/// 空白的）。
private struct SplitPartnerPane: View {
    @ObservedObject var partner: Tab
    let content: ContentView
    /// 拖动冻结宽（0.3.9）：非 nil 时真 webview 固定此宽（零 resize）。
    var frozenWidth: CGFloat?
    /// 拖动期快照层图（平台视图，盖在 webview 上拉伸跟随）。
    var snapshot: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if partner.isIncognito {
                    Image(systemName: "mask")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(partner.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    content.tabManager.setSplitPartner(at: nil)
                } label: {
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

            Divider()

            Group {
                if partner.isOnNewTabPage {
                    NewTabPage(
                        store: content.quickDialStore,
                        urlString: Binding(
                            get: { partner.urlString },
                            set: { partner.urlString = $0 }
                        ),
                        onNavigate: { input in
                            content.b.navigateToURL(input, for: partner)
                        },
                        suggestionModel: content.newTabSuggestionModel,
                        bookmarkStore: content.bookmarkStore,
                        historyStore: content.historyStore,
                        settings: content.settings
                    )
                } else {
                    ZStack(alignment: .topLeading) {
                        content.makeWebView(for: partner)
                            .frame(width: frozenWidth, alignment: .topLeading)
                        // 同主栏：拖动期真 webview 冻结，快照层跟随拉伸。
                        if let snapshot {
                            SnapshotLayerView(image: snapshot)
                        }
                    }
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(partner.id)
        }
    }
}

/// 点阵工作台背景 — 响应式模式下设备框周围的"操作台"质感。
private struct WorkbenchGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 26
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                        with: .color(Color.white.opacity(0.06))
                    )
                    y += spacing
                }
                x += spacing
            }
        }
    }
}


/// 点阵工作台背景 — 响应式模式下设备框周围的"操作台"质感。
