import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import os

extension ContentView {
    /// Navigation toolbar + address bar. Extracted from `body` (L1-1).
    /// Pure view slice — closures retained verbatim. The `toggleDarkMode`
    /// closure still holds an inline JS template; it will move to the
    /// JS Bridge in roadmap stage 1.
    @ViewBuilder
    func toolbarSection(for tab: Tab) -> some View {
        let host = tab.browser.webView.url?.host
        let isDark = host.map { siteSettingsStore.darkModeEnabled(for: $0) } ?? false
        let isBookmarked: Bool = {
            guard let url = tab.browser.webView.url?.absoluteString, !tab.isOnNewTabPage else { return false }
            return bookmarkStore.contains(url: url)
        }()
        Toolbar(
            tab: tab,
            isReadingMode: tab.browser.isReadingMode,
            isDarkMode: isDark,
            searchEngineState: .init(
                currentEngine: settings.searchEngine,
                effectiveEngineName: settings.effectiveEngineName,
                customEngines: settings.customEngines,
                selectedCustomEngineId: settings.selectedCustomEngineId,
                // Clearing the custom-engine pick is what lets a built-in
                // selection actually take effect — the custom id otherwise
                // keeps winning `searchURLTemplate` forever.
                onSelectEngine: {
                    settings.searchEngine = $0
                    settings.selectedCustomEngineId = nil
                },
                onSelectCustom: { settings.selectedCustomEngineId = $0 }
            ),
            suggestionModel: suggestionModel,
            downloadStore: downloadStore,
            passwordStore: passwordStore,
            isDevModeEnabled: devToolsStore.isDevModeEnabled,
            isUrlFocused: $isUrlFocused,
            urlFieldFrame: $urlFieldFrame,
            actions: Toolbar.Actions(
                goBack: { tab.browser.webView.goBack() },
                goForward: { tab.browser.webView.goForward() },
                reload: { tab.browser.webView.reload() },
                loadHome: { loadHome(for: tab) },
                navigate: { input in
                    suggestionModel.reset()
                    isUrlFocused = false
                    b.navigateToURL(input, for: tab)
                },
                toggleBookmark: { toggleBookmark() },
                toggleFullScreen: { toggleFullScreen() },
                inspectElement: { inspectElement() },
                suggestionSelect: { sug in
                    suggestionModel.reset()
                    isUrlFocused = false
                    // Search-shaped suggestions record history here — the
                    // URL they navigate with is already resolved, so
                    // navigateToURL can no longer tell it was a search.
                    let isSearch = sug.kind == .searchDefault || sug.kind == .searchSuggestion
                    if isSearch, !tab.isIncognito {
                        searchHistoryStore.add(query: sug.title, engine: settings.effectiveEngineName)
                    }
                    b.navigateToURL(sug.url, for: tab)
                },
                printPage: { printPage() },
                zoomIn: { zoomTab(by: 0.1) },
                zoomOut: { zoomTab(by: -0.1) },
                resetZoom: { zoomTab(to: 1.0) },
                toggleReader: {
                    if tab.browser.isReadingMode {
                        tab.browser.isReadingMode = false
                        tab.browser.isReaderLoading = false
                    } else {
                        tab.browser.isReaderLoading = true
                        tab.browser.isReadingMode = true
                        tab.browser.webView.evaluateJavaScript("window._desireReader()", completionHandler: nil)
                    }
                },
                captureFullPage: { captureFullPage() },
                captureScreenshot: { startScreenshot() },
                addToReadingList: { title, url in
                    readingListStore.add(title: title, url: url)
                },
                togglePictureInPicture: { togglePictureInPicture() },
                toggleResponsiveMode: {
                    if let tab = tabManager.selectedTab {
                        tab.responsiveConfig.isEnabled.toggle()
                    }
                },
                toggleTranslate: {
                    showTranslateBar.toggle()
                    if showTranslateBar {
                        Task {
                            await translationService.detectLanguage(webView: tab.browser.webView)
                        }
                    }
                },
                toggleDarkMode: { b.toggleDarkMode(for: tab) },
                toggleAgentPanel: { showAgentPanel.toggle() },
                toggleAgentFloatingPanel: { aiFloatingPanel?.toggle() },
                toggleDevTools: { toggleDevTools() }
            ),
            showHistory: $showHistory,
            showBookmarks: $showBookmarks,
            showPlugins: $showPlugins,
            showReadingList: $showReadingList,
            showElementBlock: $showElementBlock,
            showSearchHistory: $showSearchHistory,
            openWindow: { openWindow(id: $0) },
            onTextChange: { [bm = bookmarkStore, hist = historyStore, st = settings] newValue in
                suggestionModel.build(query: newValue, settings: st, bookmarks: bm, history: hist)
            },
            pluginStore: pluginStore,
            onRunPlugin: { plugin in
                // 固定图标点击：在当前页运行一次（隔离世界，绕过 URL 匹配）。
                let target = tab.browser.webView
                guard !tab.isOnNewTabPage else {
                    actionToast = StatusBarToast(
                        icon: plugin.toolbarIcon,
                        text: String(localized: "Open a page first")
                    )
                    return
                }
                if pluginStore.runOnce(plugin, in: target) {
                    actionToast = StatusBarToast(
                        icon: plugin.toolbarIcon,
                        text: String(localized: "Plugin \"\(plugin.name)\" ran")
                    )
                }
            },
            showDownloads: Binding(
                get: { appState.showDownloadsPanel },
                set: { appState.showDownloadsPanel = $0 }
            ),
            isBookmarked: isBookmarked
        )
    }
}
