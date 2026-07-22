import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    let appState: AppState

    @StateObject fileprivate var tabManager = TabManager()
    @StateObject fileprivate var suggestionModel = AddressSuggestionsModel()
    @StateObject fileprivate var translationService = TranslationService()
    @StateObject fileprivate var responsiveDesignStore = ResponsiveDesignStore()
    @StateObject fileprivate var thumbnailStore = TabThumbnailStore()
    @FocusState fileprivate var isUrlFocused: Bool
    @FocusState fileprivate var isFindFocused: Bool
    @State fileprivate var showTranslateBar = false
    @Environment(\.scenePhase) fileprivate var scenePhase
    @Environment(\.openWindow) fileprivate var openWindow

    // Convenience accessors for shared stores
    fileprivate var settings: Settings { appState.settings }
    fileprivate var aiSession: AISessionStore { appState.aiSession }
    fileprivate var contentBlocker: ContentBlocker { appState.contentBlocker }
    fileprivate var bookmarkStore: BookmarkStore { appState.bookmarkStore }
    fileprivate var historyStore: HistoryStore { appState.historyStore }
    fileprivate var passwordStore: PasswordStore { appState.passwordStore }
    fileprivate var formAutofillStore: FormAutofillStore { appState.formAutofillStore }
    fileprivate var downloadStore: DownloadStore { appState.downloadStore }
    fileprivate var permissionStore: PermissionStore { appState.permissionStore }
    fileprivate var siteSettingsStore: SiteSettingsStore { appState.siteSettingsStore }
    fileprivate var quickDialStore: QuickDialStore { appState.quickDialStore }
    fileprivate var readingListStore: ReadingListStore { appState.readingListStore }
    fileprivate var pluginStore: PluginStore { appState.pluginStore }
    fileprivate var tabGroupStore: TabGroupStore { appState.tabGroupStore }
    fileprivate var elementBlockStore: ElementBlockStore { appState.elementBlockStore }
    fileprivate var videoAdBlocker: VideoAdBlocker { appState.videoAdBlocker }
    fileprivate var conversationStore: ConversationStore { appState.conversationStore }
    fileprivate var devToolsStore: DevToolsStore { appState.devToolsStore }
    fileprivate var searchHistoryStore: SearchHistoryStore { appState.searchHistoryStore }

    /// Rebuilt each render from current state. Cheap — it's a value type.
    /// Routes `BrowserCommand`s from the app menus. See `CommandDispatcher`
    /// and `docs/ARCHITECTURE.md` (L1-1).
    fileprivate var commandDispatcher: CommandDispatcher {
        CommandDispatcher(
            tabManager: tabManager,
            settings: settings,
            contentBlocker: contentBlocker,
            videoAdBlocker: videoAdBlocker,
            bookmarkStore: bookmarkStore,
            historyStore: historyStore,
            openSettings: { openWindow(id: "settings") },
            bindings: .init(
                showHistory: $showHistory,
                showBookmarks: $showBookmarks,
                showPlugins: $showPlugins,
                showExtensions: $showExtensions,
                showElementBlock: $showElementBlock,
                showTabSwitcher: $showTabSwitcher,
                showSidebar: $showSidebar,
                isFindBarVisible: $isFindBarVisible
            ),
            actions: .init(
                newWindow: {
                    // Open a native SwiftUI window via the id'd WindowGroup.
                    // Each window gets its own ContentView (and TabManager),
                    // sharing the global AppState. Replaces the manual
                    // NSHostingView+NSWindow approach so window lifecycle,
                    // state restoration, and standard chrome are handled by
                    // SwiftUI. See docs/ARCHITECTURE.md (L2 multi-window).
                    openWindow(id: "main")
                },
                toggleBookmark: { toggleBookmark() },
                toggleFullScreen: { toggleFullScreen() },
                showFindBar: { showFindBar() },
                hideFindBar: { hideFindBar() },
                printPage: { printPage() },
                startScreenshot: { startScreenshot() },
                clearUrlFocus: { isUrlFocused = false }
            )
        )
    }

    @State fileprivate var isAIConfigured = false
    @State fileprivate var isFindBarVisible = false
    @State fileprivate var showHistory = false
    @State fileprivate var showBookmarks = false
    @State fileprivate var showPlugins = false
    @State fileprivate var showExtensions = false
    @State fileprivate var showReadingList = false
    @State fileprivate var showTabSwitcher = false
    @State fileprivate var showSidebar = false
    @State fileprivate var showElementBlock = false
    @State fileprivate var showSearchHistory = false
    @State fileprivate var showUndoToast = false
    @State fileprivate var screenshotToast: String?
    @State fileprivate var mediaQueries: [MediaQueryItem] = []
    @State fileprivate var videoAdBlockerToast: String?
    @State fileprivate var lastBlockedRuleId: UUID?
    @State fileprivate var lastBlockedSelector = ""
    @State fileprivate var lastBlockedXpath: String?
    @State fileprivate var findString = ""
    @State fileprivate var findHasMatch = false
    @State fileprivate var findMatchCount = 0
    @State fileprivate var findCurrentIndex = 0
    @State fileprivate var isFullScreen = false
    @State fileprivate var showAIPanel = false
    @State fileprivate var aiFloatingPanel: AIFloatingPanel?
    @State fileprivate var showDevToolsPanel = false

    var body: some View {
        VStack(spacing: 0) {
            if let tab = tabManager.selectedTab {
                tabBarSection(for: tab)
                SelectedTabContent(tab: tab, content: self)
            }
        }
        .preferredColorScheme(settings.appearanceTheme == .system ? nil : settings.appearanceTheme == .dark ? .dark : .light)
        .tint(settings.accentColor.color)
        .ignoresSafeArea(.all, edges: .top)
        .background(WindowChromeGuard())
        .onAppear {
            if aiFloatingPanel == nil {
                aiFloatingPanel = AIFloatingPanel(store: aiSession, conversationStore: conversationStore)
            }
            if !isAIConfigured {
                // Attach this window's TabManager to the shared tool surface,
                // then wire the AI agent to it. One `configure(with:)` call
                // replaces the former 13-parameter `configureStores`.
                appState.attach(tabManager: tabManager)
                aiSession.configure(with: appState)
                isAIConfigured = true
            }
            if tabManager.tabs.isEmpty {
                // Only the first window restores the saved session; later
                // user-opened windows start with a single fresh tab. Without
                // this gate, every new window would clone the saved tabs
                // (restoreSession reads global UserDefaults). See
                // AppState.hasRestoredSession.
                if !appState.hasRestoredSession {
                    appState.hasRestoredSession = true
                    let restored: Bool
                    if settings.startupBehavior == .restoreSession {
                        restored = tabManager.restoreSession(
                            javaScriptEnabled: settings.isJavaScriptEnabled,
                            contentBlocker: contentBlocker,
                            videoAdBlocker: videoAdBlocker
                        )
                    } else {
                        restored = false
                    }
                    if !restored {
                        tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition)
                    }
                } else {
                    // Subsequent window — fresh tab, no restore.
                    tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition)
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
            commandDispatcher.handle(command)
        }
        .sheet(isPresented: $showHistory) {
            HistoryPanel(store: historyStore, onSelect: { url in
                showHistory = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onClose: { showHistory = false })
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkPanel(store: bookmarkStore, onSelect: { url in
                showBookmarks = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onDelete: { bookmark in bookmarkStore.remove(bookmark) }, onClose: { showBookmarks = false })
        }
        .sheet(isPresented: $showSearchHistory) {
            SearchHistoryPanel(store: searchHistoryStore, onSelect: { query in
                showSearchHistory = false
                if let tab = tabManager.selectedTab {
                    let url = settings.searchURLTemplate
                        + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
                    navigateToURL(url, for: tab)
                }
            }, onClose: { showSearchHistory = false })
        }
        .onChange(of: showPlugins) { _, isShown in
            guard isShown else { return }
            showPlugins = false
            PluginsWindowController.shared.show(pluginStore: pluginStore)
        }
        .sheet(isPresented: $showExtensions) {
            SafariExtensionPanel(manager: appState.safariExtensionManager)
        }
        .sheet(isPresented: $showReadingList) {
            ReadingListPanel(store: readingListStore, onSelect: { url in
                showReadingList = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onClose: { showReadingList = false })
        }
        .sheet(isPresented: $showElementBlock) {
            ElementBlockPanel(store: elementBlockStore, onStartPicker: {
                if let tab = tabManager.selectedTab {
                    tab.browser.isPickingElement = true
                    tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                }
            }, onClose: { showElementBlock = false })
        }
        .overlay(alignment: .center) {
            Button("") {
                isUrlFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.mainWindow?.firstResponder?
                        .tryToPerform(#selector(NSTextField.selectText(_:)), with: nil)
                }
            }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
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
            if let tab = tabManager.selectedTab {
                Button("") {
                    tab.browser.isPickingElement = false
                    tab.browser.webView.evaluateJavaScript(WebView.exitPickerJS, completionHandler: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
            }
            Button("") { showAIPanel.toggle() }
                .keyboardShortcut("'", modifiers: .command)
                .hidden()
        }
        .overlay(alignment: .bottom) {
            if showUndoToast {
                HStack(spacing: 8) {
                    Text("Element blocked").font(.caption)
                    Button("Undo") {
                        if let id = lastBlockedRuleId {
                            elementBlockStore.remove(id: id)
                            let escaped = lastBlockedSelector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                            tabManager.selectedTab?.browser.webView.evaluateJavaScript("""
                            (function() {
                                var s = document.getElementById('desire-blocked-\(id.uuidString)');
                                if (s) s.remove();
                                document.querySelectorAll('\(escaped)').forEach(function(el) { el.style.display = ''; });
                            })();
                            """, completionHandler: nil)
                        }
                        showUndoToast = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let message = screenshotToast {
                HStack(spacing: 8) {
                    Text(message).font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let message = videoAdBlockerToast {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(message)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .clipShape(Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if showTranslateBar, let tab = tabManager.selectedTab {
                TranslateBar(
                    service: translationService,
                    webView: tab.browser.webView,
                    onDismiss: { showTranslateBar = false }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Body sections

    /// Tab strip. Extracted from `body` (L1-1) to keep `body` scannable.
    /// Pure view slice — no state or logic moved, closures retained verbatim.
    @ViewBuilder
    fileprivate func tabBarSection(for tab: Tab) -> some View {
        TabBar(
            tabs: tabManager.tabs,
            selectedIndex: tabManager.selectedIndex,
            isFullScreen: isFullScreen,
            showSwitcher: showTabSwitcher,
            onSelectTab: { index in
                isUrlFocused = false
                tabManager.selectTab(at: index)
                showTabSwitcher = false
                // 更新选中标签页的缩略图
                thumbnailStore.updateSelectedTabThumbnail(tabManager.selectedTab)
            },
            onCloseTab: { index in
                // 清除关闭标签页的缩略图缓存
                let tabId = tabManager.tabs[index].id
                thumbnailStore.clearThumbnail(for: tabId)
                tabManager.closeTab(at: index)
            },
            onAddTab: {
                tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition)
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
            onCloseOtherTabs: { index in
                // 清除其他标签页的缩略图缓存
                let keptId = tabManager.tabs[index].id
                for tab in tabManager.tabs where tab.id != keptId {
                    thumbnailStore.clearThumbnail(for: tab.id)
                }
                tabManager.closeOthers(keeping: index)
            },
            onCloseTabsToRight: { index in
                // 清除右侧标签页的缩略图缓存
                for i in (index + 1..<tabManager.tabs.count) {
                    thumbnailStore.clearThumbnail(for: tabManager.tabs[i].id)
                }
                tabManager.closeToTheRight(of: index)
            },
            onToggleAudioMute: { index in
                // 使用 Tab 的 audioMuted 属性
                tabManager.tabs[index].audioMuted.toggle()
            },
            onTogglePin: { index in
                tabManager.tabs[index].isPinned.toggle()
            },
            tabGroupStore: tabGroupStore,
            thumbnailStore: thumbnailStore,
            onCreateGroup: { index in
                let alert = NSAlert()
                alert.messageText = String(localized: "New Tab Group")
                alert.informativeText = String(localized: "Enter group name")
                let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
                alert.accessoryView = tf
                alert.addButton(withTitle: String(localized: "Create"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                if alert.runModal() == .alertFirstButtonReturn {
                    let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        let group = tabGroupStore.create(name: name)
                        let tabId = tabManager.tabs[index].id
                        tabGroupStore.addTab(tabId, to: group.id)
                    }
                }
            },
            onDuplicateTab: { index in
                tabManager.duplicateTab(at: index, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy)
            }
        )
    }

    /// Navigation toolbar + address bar. Extracted from `body` (L1-1).
    /// Pure view slice — closures retained verbatim. The `toggleDarkMode`
    /// closure still holds an inline JS template; it will move to the
    /// JS Bridge in roadmap stage 1.
    @ViewBuilder
    fileprivate func toolbarSection(for tab: Tab) -> some View {
        Toolbar(
            tab: tab,
            settings: settings,
            isReadingMode: tab.browser.isReadingMode,
            suggestionModel: suggestionModel,
            downloadStore: downloadStore,
            bookmarkStore: bookmarkStore,
            historyStore: historyStore,
            passwordStore: passwordStore,
            siteSettingsStore: siteSettingsStore,
            isDevModeEnabled: devToolsStore.isDevModeEnabled,
            isUrlFocused: $isUrlFocused,
            actions: Toolbar.Actions(
                goBack: { tab.browser.webView.goBack() },
                goForward: { tab.browser.webView.goForward() },
                reload: { tab.browser.webView.reload() },
                loadHome: { loadHome(for: tab) },
                navigate: { input in
                    suggestionModel.reset()
                    isUrlFocused = false
                    navigateToURL(input, for: tab)
                },
                toggleBookmark: { toggleBookmark() },
                toggleFullScreen: { toggleFullScreen() },
                inspectElement: { inspectElement() },
                suggestionSelect: { sug in
                    suggestionModel.reset()
                    isUrlFocused = false
                    navigateToURL(sug.url, for: tab)
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
                toggleDarkMode: {
                    guard let host = tab.browser.webView.url?.host else { return }
                    let enabled = !siteSettingsStore.darkModeEnabled(for: host)
                    siteSettingsStore.setDarkMode(enabled, for: host)
                    let js = """
                    (function() {
                        var el = document.getElementById('desire-dark-mode');
                        if (\(enabled)) {
                            if (!el) {
                                var css = 'html{filter:invert(0.9)hue-rotate(180deg)}img,video,canvas,svg,[style*="background-image"]{filter:invert(1)hue-rotate(180deg)}';
                                var s = document.createElement('style');
                                s.id = 'desire-dark-mode';
                                s.textContent = css;
                                document.head.appendChild(s);
                            }
                        } else {
                            if (el) el.remove();
                        }
                    })();
                    """
                    tab.browser.webView.evaluateJavaScript(js, completionHandler: nil)
                },
                toggleAIPanel: { showAIPanel.toggle() },
                toggleAIFloatingPanel: { aiFloatingPanel?.toggle() },
                toggleDevTools: { toggleDevTools() }
            ),
            showHistory: $showHistory,
            showBookmarks: $showBookmarks,
            showPlugins: $showPlugins,
            showReadingList: $showReadingList,
            showElementBlock: $showElementBlock,
            showSearchHistory: $showSearchHistory,
            openWindow: { openWindow(id: $0) }
        )
    }

    // MARK: - Actions

    fileprivate func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    fileprivate func toggleBookmark() {
        guard let tab = tabManager.selectedTab,
              let url = tab.browser.webView.url,
              !tab.isOnNewTabPage else { return }
        let urlString = url.absoluteString
        if let existing = bookmarkStore.find(url: urlString) {
            bookmarkStore.remove(existing)
        } else {
            bookmarkStore.add(title: tab.browser.pageTitle, url: urlString)
        }
    }

    fileprivate func inspectElement() {
        if let tab = tabManager.selectedTab, !tab.isOnNewTabPage {
            tab.browser.webView.requestInspector()
        }
    }

    fileprivate func toggleDevTools() {
        showDevToolsPanel.toggle()
        devToolsStore.toggleDevMode()
    }

    fileprivate func loadHome(for tab: Tab) {
        guard let url = URL(string: settings.homePage) else { return }
        tab.isOnNewTabPage = false
        tab.urlString = settings.homePage
        tab.browser.webView.load(URLRequest(url: url))
    }

    fileprivate func navigateToURL(_ input: String, for tab: Tab) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            if text.contains(".") {
                text = "https://" + text
            } else {
                guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
                // Record search history
                if !tab.isIncognito {
                    searchHistoryStore.add(query: text, engine: settings.searchEngine)
                }
                text = settings.searchURLTemplate + encoded
            }
        }
        guard let url = URL(string: text) else { return }
        tab.isOnNewTabPage = false
        tab.urlString = text
        tab.browser.webView.load(URLRequest(url: url))
    }

    fileprivate func showFindBar() {
        findString = ""
        findHasMatch = false
        findMatchCount = 0
        findCurrentIndex = 0
        isFindBarVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFindFocused = true
        }
    }

    fileprivate func hideFindBar() {
        isFindBarVisible = false
        findString = ""
        findHasMatch = false
        findMatchCount = 0
        findCurrentIndex = 0
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

    fileprivate func performFindAll() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else {
            findHasMatch = false
            findMatchCount = 0
            findCurrentIndex = 0
            return
        }
        let config = WKFindConfiguration()
        config.wraps = false
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
            if result.matchFound {
                findCurrentIndex = 0
            }
        }
        let escaped = findString.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        tab.browser.webView.evaluateJavaScript("""
        (function() {
            var t = '\(escaped)';
            if (!t) return 0;
            var r = new RegExp(t.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'gi');
            var c = 0, walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null, false);
            while (walk.nextNode()) { c += (walk.nodeValue.match(r) || []).length; }
            return c;
        })()
        """) { value, _ in
            if let count = value as? Int {
                DispatchQueue.main.async {
                    findMatchCount = count
                }
            }
        }
    }

    fileprivate func performFindNext() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.wraps = true
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
            if result.matchFound && findMatchCount > 0 {
                findCurrentIndex = (findCurrentIndex + 1) % findMatchCount
            }
        }
    }

    fileprivate func performFindPrevious() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = true
        config.wraps = true
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
            if result.matchFound && findMatchCount > 0 {
                findCurrentIndex = (findCurrentIndex - 1 + findMatchCount) % findMatchCount
            }
        }
    }

    fileprivate func zoomTab(by delta: Double) {
        guard let tab = tabManager.selectedTab else { return }
        let newZoom = min(5.0, max(0.5, tab.browser.pageZoom + delta))
        tab.browser.pageZoom = newZoom
        tab.browser.webView.pageZoom = newZoom
        if let host = tab.browser.webView.url?.host {
            siteSettingsStore.setZoom(newZoom, for: host)
        }
    }

    fileprivate func zoomTab(to value: Double) {
        guard let tab = tabManager.selectedTab else { return }
        tab.browser.pageZoom = value
        tab.browser.webView.pageZoom = value
        if let host = tab.browser.webView.url?.host {
            siteSettingsStore.setZoom(value, for: host)
        }
    }

    fileprivate func printPage() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.topMargin = 20
        printInfo.bottomMargin = 20
        printInfo.leftMargin = 20
        printInfo.rightMargin = 20
        let operation = tab.browser.webView.printOperation(with: printInfo)
        operation.run()
    }

    fileprivate func startScreenshot() {
        ScreenshotSession.start(saveFolder: settings.screenshotFolder) { result in
            Task { @MainActor in
                switch result {
                case .cancelled:
                    break
                case .saved(let url):
                    screenshotToast = String(format: String(localized: "Saved to %@"), url.lastPathComponent)
                case .copied:
                    screenshotToast = String(localized: "Copied to clipboard")
                }
                if screenshotToast != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        screenshotToast = nil
                    }
                }
            }
        }
    }

    fileprivate func refreshMediaQueries(for tab: Tab) {
        tab.browser.webView.evaluateJavaScript(mediaQueryExtractorJS) { result, _ in
            if let rules = result as? [[String: Any]] {
                mediaQueries = rules.map {
                    MediaQueryItem(query: $0["query"] as? String ?? "", isActive: $0["active"] as? Bool ?? false)
                }
            }
        }
    }

    fileprivate func captureResponsiveScreenshot(for tab: Tab) {
        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = CGRect(origin: .zero, size: tab.responsiveConfig.effectiveSize)
        tab.browser.webView.takeSnapshot(with: snapConfig) { image, error in
            guard let image, error == nil else { return }
            let panel = NSSavePanel()
            panel.title = String(localized: "Save Responsive Screenshot")
            panel.nameFieldStringValue = "responsive-\(Int(tab.responsiveConfig.effectiveSize.width))x\(Int(tab.responsiveConfig.effectiveSize.height)).png"
            panel.allowedContentTypes = [.png]
            panel.begin { response in
                if response == .OK, let url = panel.url,
                   let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData) {
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }

    fileprivate func captureFullPage() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let webView = tab.browser.webView
        let config = WKPDFConfiguration()
        webView.createPDF(configuration: config) { result in
            switch result {
            case .success(let pdfData):
                let panel = NSSavePanel()
                panel.title = String(localized: "Save Full Page PDF")
                panel.nameFieldStringValue = "\(tab.displayTitle).pdf"
                panel.allowedContentTypes = [.pdf]
                panel.begin { response in
                    if response == .OK, let url = panel.url {
                        try? pdfData.write(to: url)
                    }
                }
            case .failure:
                break
            }
        }
    }

    fileprivate func togglePictureInPicture() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) return;
            if (document.pictureInPictureElement) {
                document.exitPictureInPicture();
            } else if (v.readyState >= 2) {
                v.requestPictureInPicture();
            }
        })();
        """
        tab.browser.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    fileprivate func makeWebView(for tab: Tab) -> WebView {
        tab.browser.onAIElementPicked = { selector, html in
            aiSession.addContext(html: html, selector: selector)
        }
        aiSession.setWebView(tab.browser.webView)
        return WebView(
            state: tab.browser,
            downloadStore: downloadStore,
            passwordStore: passwordStore,
            formAutofillStore: formAutofillStore,
            permissionStore: permissionStore,
            siteSettingsStore: siteSettingsStore,
            devToolsStore: devToolsStore,
            urlString: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }),
            isLoading: Binding(get: { tab.isLoading }, set: { tab.isLoading = $0 }),
            canGoBack: Binding(get: { tab.canGoBack }, set: { tab.canGoBack = $0 }),
            canGoForward: Binding(get: { tab.canGoForward }, set: { tab.canGoForward = $0 }),
            httpsUpgradeEnabled: settings.httpsUpgradeEnabled,
            onOpenLinkInNewTab: { url in
                tabManager.addTab(url: url.absoluteString, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition)
            },
            onPageFinished: { url, title in
                // Reset per-page counter so the toast reflects this navigation.
                videoAdBlocker.resetCount()
                if tab.suppressHistoryOnce {
                    tab.suppressHistoryOnce = false
                } else if !tab.isIncognito {
                    historyStore.addEntry(url: url.absoluteString, title: title)
                }
                pluginStore.inject(into: tab.browser.webView, for: url)
            },
            onElementPicked: { cssSelector, xpath in
                handleElementPicked(cssSelector: cssSelector, xpath: xpath, in: tab)
            },
            onVideoAdBlocked: { count, site, action in
                let siteName = Self.videoSiteDisplayName(site)
                let actionSuffix: String
                if action == "skip" {
                    actionSuffix = String(localized: "（已跳过）")
                } else if action == "seek" {
                    actionSuffix = String(localized: "（已快进）")
                } else {
                    actionSuffix = ""
                }
                videoAdBlockerToast = String(format: String(localized: "已拦截 %d 个 %@ 广告%@"), count, siteName, actionSuffix)
                scheduleVideoAdBlockerToastReset()
            },
            onInspectedElement: { element in
                devToolsStore.setInspectedElement(element)
            },
            elementBlockStore: elementBlockStore
        )
    }

    /// Maps the JS `site` key (e.g. "youtube") to a localized display name.
    private static func videoSiteDisplayName(_ key: String?) -> String {
        switch key {
        case "youtube": String(localized: "YouTube")
        case "bilibili": String(localized: "Bilibili")
        case "tencent": String(localized: "腾讯视频")
        case "iqiyi": String(localized: "爱奇艺")
        case "youku": String(localized: "优酷")
        case "mgtv": String(localized: "芒果TV")
        case "tiktok": String(localized: "TikTok")
        case "twitter": String(localized: "X")
        default: String(localized: "视频")
        }
    }

    /// Schedules the video-ad-blocker toast to disappear after 2.5s.
    /// Uses an id-based schedule to allow overlapping updates (latest wins).
    fileprivate var videoAdBlockerToastToken: Int { 0 }
    fileprivate func scheduleVideoAdBlockerToastReset() {
        let snapshot = videoAdBlockerToast
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if videoAdBlockerToast == snapshot {
                videoAdBlockerToast = nil
            }
        }
    }
    
    fileprivate func handleElementPicked(cssSelector: String, xpath: String?, in tab: Tab) {
        guard let host = tab.browser.webView.url?.host else {
            tab.browser.isPickingElement = false
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Block this element?")
        alert.informativeText = "CSS: \(cssSelector)"
        if let xp = xpath {
            alert.informativeText += "\nXPath: \(xp)"
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Block"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let rule = BlockedElementRule(urlPattern: host, cssSelector: cssSelector, xpath: xpath)
            elementBlockStore.add(cssSelector: cssSelector, xpath: xpath, urlPattern: host)
            let escapedCss = cssSelector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            tab.browser.webView.evaluateJavaScript("""
            (function() {
                var s = document.createElement('style');
                s.id = 'desire-blocked-\(rule.id.uuidString)';
                s.textContent = '\(escapedCss) { display: none !important; }';
                document.head.appendChild(s);
            })();
            """, completionHandler: nil)
            lastBlockedRuleId = rule.id
            lastBlockedSelector = cssSelector
            lastBlockedXpath = xpath
            showUndoToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if showUndoToast {
                    showUndoToast = false
                }
            }
        }
        tab.browser.isPickingElement = false
    }
}

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
/// Private sub-view (AGENTS.md file-granularity exception 2): shares
/// `ContentView`'s state and action methods via `content`, so it lives in the
/// same file rather than being extracted out.
private struct SelectedTabContent: View {
    @ObservedObject var tab: Tab
    let content: ContentView

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

            HStack(spacing: 0) {
                if content.showSidebar {
                    SidebarView(
                        bookmarkStore: content.bookmarkStore,
                        historyStore: content.historyStore,
                        readingListStore: content.readingListStore,
                        onNavigate: { url in content.navigateToURL(url, for: tab) }
                    )
                    Divider()
                }

                VStack(spacing: 0) {
                    content.toolbarSection(for: tab)

                    if tab.responsiveConfig.isEnabled {
                        ResponsiveDesignBar(
                            config: Binding(get: { tab.responsiveConfig }, set: { tab.responsiveConfig = $0 }),
                            responsiveStore: content.responsiveDesignStore,
                            onScreenshot: { content.captureResponsiveScreenshot(for: tab) }
                        )
                    }

                    if content.isFindBarVisible {
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
                                content.navigateToURL(input, for: tab)
                            }, suggestionModel: content.suggestionModel, bookmarkStore: content.bookmarkStore, historyStore: content.historyStore, settings: content.settings)
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
                                            content.refreshMediaQueries(for: tab)
                                        }
                                    }
                                    .onChange(of: tab.responsiveConfig.effectiveSize) { _, _ in
                                        if tab.responsiveConfig.showMediaQueryInspector {
                                            content.refreshMediaQueries(for: tab)
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
                                engineName: content.settings.searchEngine.rawValue,
                                searchHistoryStore: content.searchHistoryStore,
                                onSelect: { sug in
                                    content.suggestionModel.reset()
                                    content.isUrlFocused = false
                                    content.navigateToURL(sug.url, for: tab)
                                },
                                onSearchHistorySelect: { query in
                                    content.suggestionModel.reset()
                                    content.isUrlFocused = false
                                    let url = content.settings.searchURLTemplate
                                        + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
                                    content.navigateToURL(url, for: tab)
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

                if content.showAIPanel {
                    Divider()
                        .frame(width: 1)
                    AIPanel(store: content.aiSession, conversationStore: content.conversationStore)
                        .frame(width: 320)
                }

                if content.showDevToolsPanel {
                    Divider()
                        .frame(width: 1)
                    DevToolsPanel(store: content.devToolsStore, tab: tab, onStartElementPicker: {
                        tab.browser.isPickingElement = true
                        tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                    })
                    .frame(width: 380)
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

