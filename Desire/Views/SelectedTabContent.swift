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
    let showAIPanel: Bool
    let showDevToolsPanel: Bool
    let isFindBarVisible: Bool
    /// Draggable panel widths (persisted per-session, not across launches).
    @State private var devToolsWidth: CGFloat = 420
    @State private var aiPanelWidth: CGFloat = 320

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

            HStack(spacing: 0) {
                if showSidebar {
                    SidebarView(
                        bookmarkStore: content.bookmarkStore,
                        historyStore: content.historyStore,
                        readingListStore: content.readingListStore,
                        onNavigate: { url in actions.navigateToURL(url, for: tab) }
                    )
                    Divider()
                }

                VStack(spacing: 0) {
                    if tab.responsiveConfig.isEnabled {
                        ResponsiveDesignBar(
                            config: Binding(get: { tab.responsiveConfig }, set: { tab.responsiveConfig = $0 }),
                            responsiveStore: content.responsiveDesignStore,
                            onScreenshot: { actions.captureResponsiveScreenshot(for: tab) }
                        )
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
                                    .frame(width: responsiveW, height: responsiveH)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .overlay {
                                        if tab.responsiveConfig.isEnabled {
                                            DeviceFrameOverlay(config: tab.responsiveConfig, viewportSize: effectiveSize)
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
                                    .onChange(of: tab.responsiveConfig.touchSimulationEnabled) { _, enabled in
                                        if enabled {
                                            TouchSimulation.apply(to: tab.browser.webView)
                                        } else {
                                            TouchSimulation.remove(from: tab.browser.webView)
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

                if tab.responsiveConfig.isEnabled && tab.responsiveConfig.showMediaQueryInspector {
                    Divider()
                        .frame(width: 1)
                    MediaQueryInspector(queries: content.mediaQueries)
                        .frame(width: 220)
                }

                if showAIPanel {
                    ResizableDivider(width: $aiPanelWidth, range: 260...560)
                    AIPanel(store: content.aiSession, conversationStore: content.conversationStore)
                        .frame(width: aiPanelWidth)
                }

                if showDevToolsPanel {
                    ResizableDivider(width: $devToolsWidth, range: 300...800)
                    DevToolsPanel(store: content.devToolsStore, tab: tab, onStartElementPicker: {
                        tab.browser.isPickingElement = true
                        tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                    }, onClose: { content.toggleDevTools() })
                    .frame(width: devToolsWidth)
                }
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


