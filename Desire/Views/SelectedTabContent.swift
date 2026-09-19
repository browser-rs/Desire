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

    // MARK: 拖动期快照接管（0.3.9，彻底治抖动）
    //
    // 根因：WKWebView 是进程外合成，拖动中连续改 frame 每帧都要跨进程
    // 重排 → 白闪/抖动（分屏、Agent 侧栏同病——拖 Agent 分隔条时变形
    // 的是左侧主 webview）。方案 = Chrome 的 resize 策略：拖动开始时给
    // 受影响的 webview 各截一张快照，拖动期间布局里摆的是**可拉伸的
    // 静态图**（视觉实时跟随光标，无任何 WebKit 重排），松手时换回真
    // webview、只做一次重排。截图是异步的（约一帧），期间冻结宽度。
    @State private var panelResizeSnapshots: (main: NSImage, partner: NSImage?)?
    @State private var resizeWidthFollowsDrag = false
    /// 代数令牌：快速"按下→松开"时迟到快照回调不得重新进入快照态。
    @State private var resizeGeneration = 0

    private func beginPanelResize() {
        guard panelResizeSnapshots == nil else { return }
        resizeGeneration += 1
        let generation = resizeGeneration
        let partnerWebView = content.tabManager.splitPartner?.browser.webView
        let group = DispatchGroup()
        var mainImg: NSImage?
        var partnerImg: NSImage?
        group.enter()
        tab.browser.webView.takeSnapshot(with: nil) { img, _ in
            mainImg = img
            group.leave()
        }
        if let partnerWebView {
            group.enter()
            partnerWebView.takeSnapshot(with: nil) { img, _ in
                partnerImg = img
                group.leave()
            }
        }
        group.notify(queue: .main) { [self] in
            guard generation == resizeGeneration else { return }
            panelResizeSnapshots = (mainImg ?? NSImage(), partnerImg)
            withAnimation(nil) { resizeWidthFollowsDrag = true }
        }
    }

    private func endPanelResize() {
        resizeGeneration += 1
        resizeWidthFollowsDrag = false
        panelResizeSnapshots = nil
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
                if showAgentPanel {
                    WorkbenchGrid()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
                        } else if let mainSnap = panelResizeSnapshots?.main {
                            // 拖动期：静态快照填满（无 WebKit 重排）。
                            GeometryReader { geo in
                                Image(nsImage: mainSnap)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                                    .background(Color(nsColor: .windowBackgroundColor))
                            }
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
                    // 分屏浏览（0.2.15）：拖动走快照接管（见
                    // beginPanelResize 注释）——拖动期页面零重排。
                    PanelResizeDivider(width: $splitPaneWidth, range: 220...1400,
                                       dragStarted: { beginPanelResize() },
                                       mayUpdateWidth: { resizeWidthFollowsDrag },
                                       dragEnded: { endPanelResize() })
                    SplitPartnerPane(partner: partner, content: content,
                                     snapshot: panelResizeSnapshots?.partner)
                        .frame(width: splitPaneWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if tab.responsiveConfig.isEnabled && tab.responsiveConfig.showMediaQueryInspector {
                    MediaQueryInspector(queries: content.mediaQueries)
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 560)
                }

                if showAgentPanel {
                    PanelResizeDivider(width: $agentPanelWidth, range: 260...1200,
                                       dragStarted: { beginPanelResize() },
                                       mayUpdateWidth: { resizeWidthFollowsDrag },
                                       dragEnded: { endPanelResize() })
                    AgentPanel(store: content.aiSession, conversationStore: content.conversationStore)
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
                    PanelResizeDivider(width: $devToolsWidth, range: 300...1400,
                                       dragStarted: { beginPanelResize() },
                                       mayUpdateWidth: { resizeWidthFollowsDrag },
                                       dragEnded: { endPanelResize() })
                    DevToolsPanel(store: content.devToolsStore, tab: tab, onStartElementPicker: {
                        tab.browser.isPickingElement = true
                        tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                    }, onClose: { content.toggleDevTools() })
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




/// 面板分隔条（0.3.9 统一版）：分屏 / Agent / DevTools 共用。
/// 手势语义与 ResizableDivider 相同（基线宽度 + 累计 translation），
/// 差异：宽度只在 `mayUpdateWidth()` 为真时更新——面板内容在等快照
/// 接管（异步截屏约一帧）期间布局冻结，杜绝任何 WebKit 重排。
/// `dragStarted` 触发快照捕获，`dragEnded` 交回真视图。
private struct PanelResizeDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let dragStarted: () -> Void
    let mayUpdateWidth: () -> Bool
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
                        guard mayUpdateWidth() else { return }
                        if dragStartWidth == nil { dragStartWidth = width }
                        width = (dragStartWidth! - value.translation.width)
                            .clamped(to: range)
                    }
                    .onEnded { value in
                        guard isDragging else { return }
                        if mayUpdateWidth() {
                            width = ((dragStartWidth ?? width) - value.translation.width)
                                .clamped(to: range)
                        }
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
    /// 拖动期快照（0.3.9）：非 nil 时替代活 webview（无重排）。
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
                    content.makeWebView(for: partner)
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
