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
/// directly here via `@ObservedObject`.
///
/// 0.3.10：尾侧面板（分屏右栏 / Agent / DevTools / 媒体查询检查器）全部
/// 改为 **HSplitView 子视图**——SwiftUI 原生分隔条，拖拽/宽度全部由系统
/// 管理，本视图零拖拽代码、零冻结/快照机制（历轮方案均因 webview 实时
/// resize 的跨进程过场闪烁与自研机制的额外开销被否，见 git 历史）。
/// 宽度协商只经子视图的 minWidth/idealWidth/maxWidth 接口（容器所有），
/// 面板内部不得再设固定 `.frame(width:)`。
struct SelectedTabContent: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
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
    /// Native window fullscreen (⌃⌘F). Fullscreen collapses the progress bar,
    /// toolbar and bookmark bar to zero height so the web content — and with
    /// it the page viewport — is the whole screen, the way Safari and Chrome
    /// treat fullscreen. Site-initiated video fullscreen uses WebKit's own
    /// screen-covering window instead, so it does not depend on this flag.
    let isFullScreen: Bool
    /// Sends an AI prompt (and opens the panel) from the selection bar.
    let onAskAI: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFullScreen {
                GeometryReader { geo in
                    Capsule()
                        .fill(appAccent.opacity(0.15))
                        .frame(height: 2)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(appAccent)
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
            }
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

                    HSplitView {
                        mainPane
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                        if let partner = content.tabManager.splitPartner, partner.id != tab.id {
                            SplitPartnerPane(partner: partner, content: content)
                                .frame(minWidth: 220, idealWidth: 420, maxWidth: 1400, maxHeight: .infinity)
                        }

                        if tab.responsiveConfig.isEnabled && tab.responsiveConfig.showMediaQueryInspector {
                            MediaQueryInspector(queries: content.mediaQueries)
                                .frame(minWidth: 180, idealWidth: 220, maxWidth: 560)
                        }

                        if showAgentPanel {
                            AgentPanel(store: content.aiSession, conversationStore: content.conversationStore)
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
                                .frame(minWidth: 260, idealWidth: 320, maxWidth: 1200, maxHeight: .infinity)
                        }

                        if showDevToolsPanel {
                            DevToolsPanel(
                                store: content.devToolsStore,
                                tab: tab,
                                onStartElementPicker: {
                                    tab.browser.isPickingElement = true
                                    tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                                },
                                onClose: { content.toggleDevTools() }
                            )
                            .frame(minWidth: 300, idealWidth: 420, maxWidth: 1400, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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

    // MARK: - 主内容区（HSplitView 首个子视图）

    @ViewBuilder
    private var mainPane: some View {
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
}

/// 分屏右栏（0.2.15）：并排显示的第二个标签的活动 webview。顶部一条
/// 迷你标题（标签标题 + 退出分屏）让右栏看起来是个成型的面板而不是
/// 裸贴的第二个网页。工具栏/查找条/阅读模式/响应式模式是选中标签专属
/// 机制，不复制到右栏；新标签页对象仍用 NewTabPage（webview 此时是
/// 空白的）。
private struct SplitPartnerPane: View {
    @ObservedObject var partner: Tab
    let content: ContentView

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
            var y: CGFloat = 0
            while x < size.width {
                y = 0
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
