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
        let isSiteAutoPlayAllowed = host.map {
            siteSettingsStore.isAutoPlayAllowed(for: $0, global: settings.autoPlayPolicy)
        } ?? false
        let isBilingual = bilingualService.isOn(tabID: tab.id)
        let isBookmarked: Bool = {
            guard let url = tab.browser.webView.url?.absoluteString, !tab.isOnNewTabPage else { return false }
            return bookmarkStore.contains(url: url)
        }()
        Toolbar(
            tab: tab,
            browserState: tab.browser,
            isReadingMode: tab.browser.isReadingMode,
            isDarkMode: isDark,
            isSiteAutoPlayAllowed: isSiteAutoPlayAllowed,
            isBilingualOn: isBilingual,
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
            syncStore: appState.syncStore,
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
                suggestionSelect: { [tm = tabManager] sug in
                    suggestionModel.reset()
                    isUrlFocused = false
                    // 切换到已打开标签（v0.8.6）：选中即切过去，不再当 URL 重复导航。
                    if sug.kind == .openTab, let id = sug.tabID,
                       let idx = tm.tabs.firstIndex(where: { $0.id == id }) {
                        tm.selectTab(at: idx)
                        return
                    }
                    // 内联计算器（v0.8.6）：回车 = 复制结果，不导航
                    //（calculator://408 不是合法 URL，导航必然报错）。
                    if sug.kind == .calculator {
                        let result = sug.url.replacingOccurrences(of: "calculator://", with: "")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result, forType: .string)
                        actionToast = StatusBarToast(
                            icon: "plus.forwardslash.minus",
                            text: String(format: String(localized: "已复制 %@"), result))
                        return
                    }
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
                toggleSiteAutoPlay: { b.toggleSiteAutoPlay(for: tab) },
                organizeTabs: { b.organizeTabs() },
                undoOrganizeTabs: { b.undoOrganizeTabs() },
                organizeTabsByTopic: { await b.organizeTabsByTopic() },
                toggleAgentPanel: { showAgentPanel.toggle() },
                toggleAgentFloatingPanel: { aiFloatingPanel?.toggle() },
                toggleDevTools: { toggleDevTools() },
                toggleBilingual: { b.toggleBilingual(for: tab) },
                siteControls: Toolbar.SiteControlActions(
                    zoomIn: { b.zoom(by: 0.1) },
                    zoomOut: { b.zoom(by: -0.1) },
                    zoomReset: { b.zoom(to: 1.0) },
                    toggleDarkMode: { b.toggleDarkMode(for: tab) },
                    toggleAutoPlay: { b.toggleSiteAutoPlay(for: tab) },
                    manageBlocked: {
                        // 关弹层由 Toolbar 本地补全（showSecurityInfo 是它的状态）。
                        showElementBlock = true
                    },
                    clearOverrides: { b.clearSiteControls(for: tab) },
                    watchPage: {
                        guard let url = tab.browser.webView.url?.absoluteString else { return }
                        let host = tab.browser.webView.url?.host ?? "page"
                        let name = "\(host) — \(tab.displayTitle.prefix(28))"
                        guard !PageWatchStore.shared.watches.contains(where: { $0.url == url }) else { return }
                        _ = PageWatchStore.shared.add(name: name, url: url,
                                                      selector: nil, minutes: 30)
                    },
                    recordWorkflow: {
                        guard let url = tab.browser.webView.url?.absoluteString else { return }
                        WorkflowStore.shared.startRecording(url: url)
                        tab.browser.webView.evaluateJavaScript(
                            "window.__desireWorkflowRecording = true", completionHandler: nil)
                    }
                )
            ),
            showHistory: $showHistory,
            showBookmarks: $showBookmarks,
            showPlugins: $showPlugins,
            showReadingList: $showReadingList,
            showElementBlock: $showElementBlock,
            showSearchHistory: $showSearchHistory,
            openWindow: { openWindow(id: $0) },
            onTextChange: { [bm = bookmarkStore, hist = historyStore, st = settings, tm = tabManager] newValue in
                // 切换到标签（v0.8.6 旗舰 A）：建议模型需要本窗口的打开标签——
                // 此前 openTabs 无人赋值，切换建议从未出现在真实 UI 里。
                suggestionModel.openTabs = tm.tabs.compactMap { tab in
                    let url = tab.browser.webView.url?.absoluteString ?? tab.urlString
                    guard !url.isEmpty, !tab.isOnNewTabPage else { return nil }
                    return AddressSuggestionsModel.OpenTabInfo(
                        id: tab.id,
                        title: tab.displayTitle.isEmpty ? url : tab.displayTitle,
                        url: url)
                }
                suggestionModel.build(query: newValue, settings: st, bookmarks: bm, history: hist)
            },
            pluginStore: pluginStore,
            tabToSearch: { input in
                URLResolution.tabToSearchKeyword(in: input, settings: settings)
            },
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
            showWorkspaces: Binding(
                get: { appState.showWorkspacesPanel },
                set: { appState.showWorkspacesPanel = $0 }
            ),
            siteSettingsStore: siteSettingsStore,
            globalAutoPlay: settings.autoPlayPolicy,
            blockedElementCount: host.map { elementBlockStore.matchingRules(for: $0).count },
            isBookmarked: isBookmarked
        )
    }
}
