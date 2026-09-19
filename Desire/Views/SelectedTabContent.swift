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
/// 0.3.9：内容区布局下沉 AppKit（PanelSplitHost——主 webview/分屏右栏/
/// Agent/DevTools 面板 + 分隔条）。SwiftUI 保留：进度条、工具栏、书签栏、
/// 通知条、响应式条、查找条、侧栏、底部链接预览与内容区浮层
/// （地址建议/错误页——声明在平台容器之后，必然盖在其上）。
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
    /// 面板宽度（会话内持久；实时值由 AppKit 容器自持，拖动结束才回写）。
    @State private var devToolsWidth: CGFloat = 420
    @State private var agentPanelWidth: CGFloat = 320
    @State private var splitPaneWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            // 进度条
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

            // Toolbar spans full width above the content area.
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

                    // AppKit 分屏内核（0.3.9）：主 webview + 分屏右栏 +
                    // Agent/DevTools 面板 + 分隔条整块下沉（PanelSplitHost）。
                    // 拖动全程不经 SwiftUI 布局——外部会诊定案。
                    PanelSplitHost(
                        tab: tab,
                        content: content,
                        actions: actions,
                        agentVisible: showAgentPanel,
                        devVisible: showDevToolsPanel,
                        overviewVisible: content.showTabOverview,
                        onWidthsCommitted: { partner, agent, devtools in
                            splitPaneWidth = partner
                            agentPanelWidth = agent
                            devToolsWidth = devtools
                        },
                        seedWidths: (splitPaneWidth, agentPanelWidth, devToolsWidth))
                    // 高频浮层仍由 SwiftUI 承担（声明在平台容器之后 =
                    // 必然盖在其上）：地址建议下拉、错误页。
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
