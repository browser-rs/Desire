import AppKit
import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var tabManager = TabManager()
    @FocusState private var isUrlFocused: Bool
    @FocusState private var isFindFocused: Bool
    @StateObject private var settings = Settings()
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var bookmarkStore = BookmarkStore()
    @StateObject private var userScriptStore = UserScriptStore()
    @StateObject private var contentBlocker = ContentBlocker()
    @StateObject private var suggestionModel = AddressSuggestionsModel()
    @StateObject private var downloadStore = DownloadStore()
    @StateObject private var quickDialStore = QuickDialStore()
    @Environment(\.scenePhase) private var scenePhase

    @State private var isFindBarVisible = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var showUserScripts = false
    @State private var showTabSwitcher = false
    @State private var findString = ""
    @State private var findHasMatch = false
    @State private var isFullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            if let tab = tabManager.selectedTab {
                TabBar(
                    tabs: tabManager.tabs,
                    selectedIndex: tabManager.selectedIndex,
                    isFullScreen: isFullScreen,
                    showSwitcher: showTabSwitcher,
                    onSelectTab: { index in
                        isUrlFocused = false
                        tabManager.selectTab(at: index)
                        showTabSwitcher = false
                    },
                    onCloseTab: { tabManager.closeTab(at: $0) },
                    onAddTab: {
                        tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                        showTabSwitcher = false
                    },
                    onMoveTab: { tabManager.moveTab(from: $0, to: $1) },
                    onReloadTab: { $0.browser.webView.reload() },
                    onCopyTabURL: { tab in
                        if let url = tab.browser.webView.url {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    },
                    onCloseOtherTabs: { tabManager.closeOthers(keeping: $0) },
                    onCloseTabsToRight: { tabManager.closeToTheRight(of: $0) }
                )

                Toolbar(
                    tab: tab,
                    settings: settings,
                    suggestionModel: suggestionModel,
                    downloadStore: downloadStore,
                    bookmarkStore: bookmarkStore,
                    historyStore: historyStore,
                    isUrlFocused: $isUrlFocused,
                    showHistory: $showHistory,
                    showBookmarks: $showBookmarks,
                    showUserScripts: $showUserScripts,
                    showSettings: $showSettings,
                    onGoBack: { tab.browser.webView.goBack() },
                    onGoForward: { tab.browser.webView.goForward() },
                    onReload: { tab.browser.webView.reload() },
                    onLoadHome: { loadHome(for: tab) },
                    onNavigate: { input in
                        suggestionModel.reset()
                        isUrlFocused = false
                        navigateToURL(input, for: tab)
                    },
                    onToggleBookmark: { toggleBookmark() },
                    onToggleFullScreen: { toggleFullScreen() },
                    onInspectElement: { inspectElement() },
                    onSuggestionSelect: { sug in
                        suggestionModel.reset()
                        isUrlFocused = false
                        navigateToURL(sug.url, for: tab)
                    }
                )
            }

            if let tab = tabManager.selectedTab {
                ProgressView(value: tab.browser.estimatedProgress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: tab.isLoading ? 2 : 0)
                    .opacity(tab.isLoading ? 1 : 0)

                if isFindBarVisible {
                    FindBar(
                        findString: $findString,
                        findHasMatch: findHasMatch,
                        isFindFocused: $isFindFocused,
                        onFindNext: { performFindNext() },
                        onFindPrevious: { performFindPrevious() },
                        onHide: { hideFindBar() },
                        onFindAll: { performFindAll() }
                    )
                }

                Group {
                    if tab.isOnNewTabPage {
                        NewTabPage(store: quickDialStore, urlString: Binding(
                            get: { tab.urlString },
                            set: { tab.urlString = $0 }
                        ), onNavigate: { input in
                            navigateToURL(input, for: tab)
                        })
                    } else {
                        WebView(
                            state: tab.browser,
                            downloadStore: downloadStore,
                            urlString: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }),
                            isLoading: Binding(get: { tab.isLoading }, set: { tab.isLoading = $0 }),
                            canGoBack: Binding(get: { tab.canGoBack }, set: { tab.canGoBack = $0 }),
                            canGoForward: Binding(get: { tab.canGoForward }, set: { tab.canGoForward = $0 }),
                            onOpenLinkInNewTab: { url in
                                tabManager.addTab(url: url.absoluteString, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                            },
                            onPageFinished: { url, title in
                                if tab.suppressHistoryOnce {
                                    tab.suppressHistoryOnce = false
                                } else if !tab.isIncognito {
                                    historyStore.addEntry(url: url.absoluteString, title: title)
                                }
                                userScriptStore.injectScripts(into: tab.browser.webView)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .id(tab.id)
                .overlay(alignment: .top) {
                    if isUrlFocused && !suggestionModel.isEmpty {
                        AddressSuggestionsView(
                            model: suggestionModel,
                            engineName: settings.searchEngine.rawValue
                        ) { sug in
                            suggestionModel.reset()
                            isUrlFocused = false
                            navigateToURL(sug.url, for: tab)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .background(WindowChromeGuard())
        .onAppear {
            if tabManager.tabs.isEmpty {
                let restored = tabManager.restoreSession(
                    javaScriptEnabled: settings.isJavaScriptEnabled,
                    contentBlocker: contentBlocker
                )
                if !restored {
                    tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                tabManager.persistSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserCommand)) { notification in
            guard let command = notification.object as? BrowserCommand else { return }
            switch command {
            case .newTab:
                tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                showTabSwitcher = false
            case .newIncognitoTab:
                tabManager.addTab(incognito: true, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                showTabSwitcher = false
            case .closeTab:
                tabManager.closeTab(at: tabManager.selectedIndex)
            case .previousTab:
                guard tabManager.selectedIndex > 0 else { return }
                isUrlFocused = false
                tabManager.selectTab(at: tabManager.selectedIndex - 1)
            case .nextTab:
                guard tabManager.selectedIndex < tabManager.tabs.count - 1 else { return }
                isUrlFocused = false
                tabManager.selectTab(at: tabManager.selectedIndex + 1)
            case .bookmarkPage: toggleBookmark()
            case .toggleFullScreen: toggleFullScreen()
            case .toggleFind:
                if isFindBarVisible { hideFindBar() } else { showFindBar() }
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryPanel(store: historyStore, onSelect: { url in
                showHistory = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onClose: { showHistory = false })
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, contentBlocker: contentBlocker, downloadStore: downloadStore, onDone: { showSettings = false })
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkPanel(store: bookmarkStore, onSelect: { url in
                showBookmarks = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onDelete: { bookmark in bookmarkStore.remove(bookmark) }, onClose: { showBookmarks = false })
        }
        .sheet(isPresented: $showUserScripts) {
            UserScriptPanel(store: userScriptStore, onAdd: addUserScript, onClose: { showUserScripts = false })
        }
        .overlay {
            Button("") {
                isUrlFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.mainWindow?.firstResponder?
                        .tryToPerform(#selector(NSTextField.selectText(_:)), with: nil)
                }
            }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.reload() } }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
                .hidden()
            Button("") {
                if let tab = tabManager.selectedTab {
                    tab.browser.webView.pageZoom = tab.browser.webView.pageZoom + 0.1
                }
            }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
            Button("") {
                if let tab = tabManager.selectedTab {
                    tab.browser.webView.pageZoom = tab.browser.webView.pageZoom - 0.1
                }
            }
                .keyboardShortcut("-", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.pageZoom = 1 } }
                .keyboardShortcut("0", modifiers: .command)
                .hidden()
            Button("") { showFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("") { performFindNext() }
                .keyboardShortcut("g", modifiers: .command)
                .hidden()
            Button("") { performFindPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .hidden()
            Button("") { hideFindBar() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
            Button("") { inspectElement() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .hidden()
        }
    }

    // MARK: - Actions

    private func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    private func toggleBookmark() {
        guard let tab = tabManager.selectedTab,
              let url = tab.browser.webView.url,
              !tab.isOnNewTabPage else { return }
        let urlString = url.absoluteString
        if let existing = bookmarkStore.bookmarks.first(where: { $0.url == urlString }) {
            bookmarkStore.remove(existing)
        } else {
            bookmarkStore.add(title: tab.browser.pageTitle, url: urlString)
        }
    }

    private func inspectElement() {
        if let tab = tabManager.selectedTab, !tab.isOnNewTabPage {
            tab.browser.webView.requestInspector()
        }
    }

    private func loadHome(for tab: Tab) {
        guard let url = URL(string: settings.homePage) else { return }
        tab.isOnNewTabPage = false
        tab.urlString = settings.homePage
        tab.browser.webView.load(URLRequest(url: url))
    }

    private func navigateToURL(_ input: String, for tab: Tab) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            if text.contains(".") {
                text = "https://" + text
            } else {
                text = settings.searchURLTemplate + text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            }
        }
        guard let url = URL(string: text) else { return }
        tab.isOnNewTabPage = false
        tab.urlString = text
        tab.browser.webView.load(URLRequest(url: url))
    }

    private func showFindBar() {
        findString = ""
        findHasMatch = false
        isFindBarVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFindFocused = true
        }
    }

    private func hideFindBar() {
        isFindBarVisible = false
        findString = ""
        findHasMatch = false
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

    private func performFindAll() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else {
            findHasMatch = false
            return
        }
        let config = WKFindConfiguration()
        config.wraps = false
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
        }
    }

    private func performFindNext() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.wraps = true
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
        }
    }

    private func performFindPrevious() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = true
        config.wraps = true
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
        }
    }

    private func addUserScript() {
        showUserScripts = false
        userScriptStore.add(name: "新脚本", urlPattern: "*", code: "// 在此编写你的 JavaScript 代码\nconsole.log('Desire user script loaded');")
    }
}
