import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - SelectedTabContent

/// 0.3.9 终版：三个尾侧面板（分屏右栏 / Agent / DevTools）全部改用
/// **系统 `.inspector`**——底层 NSSplitView，分隔条与拖拽由系统提供
/// （Safari/Finder 同款），彻底删除自研分隔条/快照/冻结机制。六轮自研
/// 拖拽失败的教训：不要自己写 webview 拖拽，用系统的。
struct SelectedTabContent: View {
    @ObservedObject var tab: Tab
    let content: ContentView
    let actions: BrowsingActions
    let showSidebar: Bool
    @Binding var showAgentPanel: Bool
    @Binding var showDevToolsPanel: Bool
    let isFindBarVisible: Bool
    let onAskAI: (String) -> Void

    /// 分屏右栏显隐（绑定到 splitPartnerID 有无）。
    private var splitBinding: Binding<Bool> {
        Binding(
            get: { content.tabManager.splitPartner != nil },
            set: { if !$0 { content.tabManager.setSplitPartner(at: nil) } }
        )
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
                        } else {
                            GeometryReader { geo in
                                let effectiveSize = tab.responsiveConfig.effectiveSize
                                let responsiveW: CGFloat? = tab.responsiveConfig.isEnabled ? min(effectiveSize.width, geo.size.width - 40) : nil
                                let responsiveH: CGFloat? = tab.responsiveConfig.isEnabled ? min(effectiveSize.height, geo.size.height - 40) : nil
                                content.makeWebView(for: tab)
                                    .overlay(alignment: .topLeading) {
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
                                                }
                                            )
                                            .offset(
                                                x: min(max(selection.viewportX * tab.browser.pageZoom, 8), max(geo.size.width - 220, 8)),
                                                y: min(max(selection.viewportY * tab.browser.pageZoom + 10, 8), max(geo.size.height - 40, 8))
                                            )
                                        }
                                    }
                                    .frame(width: responsiveW, height: responsiveH)
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
                                        ResponsiveModeApplier.apply(enabled, to: tab)
                                    }
                                    .onChange(of: tab.responsiveConfig.effectiveSize) { _, size in
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
                        }
                    }
                    .overlay {
                        if let error = tab.browser.lastError, !tab.isOnNewTabPage {
                            ErrorPageView(error: error, tab: tab)
                        }
                    }
                    .background {
                        if tab.responsiveConfig.isEnabled {
                            WorkbenchGrid()
                        }
                    }
                    // ===== 系统面板链（0.3.9 终版）：NSSplitView 背书，=====
                    // ===== 分隔条拖拽由系统提供，零自研。          =====
                    .inspector(isPresented: splitBinding) {
                        splitPane
                            .inspectorColumnWidth(min: 220, ideal: 420, max: 1200)
                    }
                    .inspector(isPresented: $showAgentPanel) {
                        AgentPanel(store: content.aiSession, conversationStore: content.conversationStore)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 1000)
                            .onAppear {
                                Task { @MainActor in
                                    content.aiSession.resumeLatestConversation()
                                }
                            }
                    }
                    .inspector(isPresented: $showDevToolsPanel) {
                        DevToolsPanel(store: content.devToolsStore, tab: tab, onStartElementPicker: {
                            tab.browser.isPickingElement = true
                            tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                        }, onClose: { content.toggleDevTools() })
                        .inspectorColumnWidth(min: 300, ideal: 420, max: 1200)
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

    // MARK: - 分屏右栏（inspector 内容）

    @ViewBuilder
    private var splitPane: some View {
        if let partner = content.tabManager.splitPartner {
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
