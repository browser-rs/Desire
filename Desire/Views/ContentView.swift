import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    let appState: AppState

    @StateObject var tabManager = TabManager()
    @StateObject var suggestionModel = AddressSuggestionsModel()
    /// The new-tab page's search box gets its OWN suggestion model — sharing
    /// one instance with the toolbar meant typing in either field repopulated
    /// the other's dropdown.
    @StateObject var newTabSuggestionModel = AddressSuggestionsModel()
    @StateObject var translationService = TranslationService()
    @StateObject var responsiveDesignStore = ResponsiveDesignStore()
    @StateObject var thumbnailStore = TabThumbnailStore()
    /// Singleton observed so the TabBar's container menu stays current.
    @ObservedObject var containerStore = ContainerStore.shared
    /// Extracted business-logic coordinator. Replaces the ~25 action methods
    /// that previously lived on ContentView.
    @StateObject var b: BrowsingActions
    @FocusState var isUrlFocused: Bool
    @FocusState var isFindFocused: Bool
    @State var showTranslateBar = false
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.openWindow) var openWindow

    init(appState: AppState) {
        self.appState = appState
        let tm = TabManager()
        _tabManager = StateObject(wrappedValue: tm)
        tm.onRequestWindowClose = { NSApp.keyWindow?.close() }
        _suggestionModel = StateObject(wrappedValue: AddressSuggestionsModel())
        _newTabSuggestionModel = StateObject(wrappedValue: AddressSuggestionsModel())
        _translationService = StateObject(wrappedValue: TranslationService())
        _responsiveDesignStore = StateObject(wrappedValue: ResponsiveDesignStore())
        _thumbnailStore = StateObject(wrappedValue: TabThumbnailStore())
        _b = StateObject(wrappedValue: BrowsingActions(
            tabManager: tm,
            settings: appState.settings,
            bookmarkStore: appState.bookmarkStore,
            historyStore: appState.historyStore,
            siteSettingsStore: appState.siteSettingsStore,
            searchHistoryStore: appState.searchHistoryStore,
            elementBlockStore: appState.elementBlockStore,
            devToolsStore: appState.devToolsStore,
            contentBlocker: appState.contentBlocker,
            videoAdBlocker: appState.videoAdBlocker
        ))
    }

    // Convenience accessors for shared stores
    var settings: Settings { appState.settings }
    var aiSession: AISessionStore { appState.aiSession }
    var contentBlocker: ContentBlockerStore { appState.contentBlocker }
    var bookmarkStore: BookmarkStore { appState.bookmarkStore }
    var historyStore: HistoryStore { appState.historyStore }
    var passwordStore: PasswordStore { appState.passwordStore }
    var formAutofillStore: FormAutofillStore { appState.formAutofillStore }
    var downloadStore: DownloadStore { appState.downloadStore }
    var permissionStore: PermissionStore { appState.permissionStore }
    var siteSettingsStore: SiteSettingsStore { appState.siteSettingsStore }
    var quickDialStore: QuickDialStore { appState.quickDialStore }
    var readingListStore: ReadingListStore { appState.readingListStore }
    var pluginStore: PluginStore { appState.pluginStore }
    var tabGroupStore: TabGroupStore { appState.tabGroupStore }
    var elementBlockStore: ElementBlockStore { appState.elementBlockStore }
    var videoAdBlocker: VideoAdBlocker { appState.videoAdBlocker }
    var conversationStore: ConversationStore { appState.conversationStore }
    var devToolsStore: DevToolsStore { appState.devToolsStore }
    var searchHistoryStore: SearchHistoryStore { appState.searchHistoryStore }

    /// Rebuilt each render from current state. Cheap — it's a value type.
    /// Routes `BrowserCommand`s from the app menus. See `CommandDispatcher`
    /// and `docs/ARCHITECTURE.md` (L1-1).
    var commandDispatcher: CommandDispatcher {
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

    @State var isAIConfigured = false
    @State var isFindBarVisible = false
    @State var showHistory = false
    @State var showBookmarks = false
    @State var showPlugins = false
    @State var showExtensions = false
    @State var showReadingList = false
    @State var showTabSwitcher = false
    @State var showSidebar = false
    @State var showElementBlock = false
    @State var showSearchHistory = false
    @State var showUndoToast = false
    @State var mediaQueries: [MediaQueryItem] = []
    @State var videoAdBlockerToast: String?
    @State var lastBlockedRuleId: UUID?
    @State var lastBlockedSelector = ""
    @State var lastBlockedXpath: String?
    @State var findString = ""
    @State var findHasMatch = false
    @State var findMatchCount = 0
    @State var findCurrentIndex = 0
    @State var isFullScreen = false
    @State var showAIPanel = false
    @State var aiFloatingPanel: AIFloatingPanel?
    @State var showDevToolsPanel = false

    var body: some View {
        VStack(spacing: 0) {
            if let tab = tabManager.selectedTab {
                tabBarSection(for: tab)
                SelectedTabContent(
                    tab: tab, content: self, actions: b,
                    showSidebar: showSidebar,
                    showAIPanel: $showAIPanel,
                    showDevToolsPanel: showDevToolsPanel,
                    isFindBarVisible: isFindBarVisible,
                    onAskAI: { prompt in
                        aiSession.sendMessage(prompt)
                        showAIPanel = true
                    }
                )
            }
        }
        .preferredColorScheme(settings.appearanceTheme == .system ? nil : settings.appearanceTheme == .dark ? .dark : .light)
        .tint(settings.accentColor.color)
        .ignoresSafeArea(.all, edges: .top)
        .background(WindowChromeGuard {
            // This window just became key — re-bind the per-window TabManager
            // so AI tools and window-scoped state target the ACTIVE window.
            appState.attach(tabManager: tabManager)
        })
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
                if !appState.hasRestoredSession {
                    // First window restores the saved session; later windows
                    // get a fresh tab — the gate lives on AppState so
                    // additional windows never clone the saved tabs.
                    appState.hasRestoredSession = true
                    b.restoreSessionOrOpenFreshTab()
                } else {
                    b.openFreshTab()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                // App hidden/terminated: force a full re-archive so the blob
                // on disk reflects the final state, not the last fingerprint
                // hit.
                tabManager.persistSession(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onReceive(CommandBus.shared.publisher) { command in
            commandDispatcher.handle(command)
        }
        .onChange(of: b.undoRule?.id) { _, ruleID in
            // BrowsingActions publishes the interception; the toast lives in
            // view state — bridge the two (this link was missing, so the
            // undo toast never appeared).
            guard let ruleID, let rule = b.undoRule else { return }
            lastBlockedRuleId = ruleID
            lastBlockedSelector = b.undoCssSelector
            showUndoToast = true
            _ = rule
        }
        .modifier(PanelsRouter(
            settings: settings,
            historyStore: historyStore,
            bookmarkStore: bookmarkStore,
            searchHistoryStore: searchHistoryStore,
            readingListStore: readingListStore,
            elementBlockStore: elementBlockStore,
            pluginStore: pluginStore,
            extensionManager: appState.safariExtensionManager,
            showHistory: $showHistory,
            showBookmarks: $showBookmarks,
            showSearchHistory: $showSearchHistory,
            showPlugins: $showPlugins,
            showExtensions: $showExtensions,
            showReadingList: $showReadingList,
            showElementBlock: $showElementBlock,
            onNavigate: { url in
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            },
            onStartElementPicker: {
                if let tab = tabManager.selectedTab {
                    tab.browser.isPickingElement = true
                    tab.browser.webView.evaluateJavaScript(WebView.pickerJS, completionHandler: nil)
                }
            },
            onDeleteBookmark: { bookmarkStore.remove($0) }
        ))
        .overlay(alignment: .center) { shortcutOverlayButtons }
        .overlay(alignment: .bottom) { undoToastOverlay }
        .overlay(alignment: .bottom) { screenshotToastOverlay }
        .overlay(alignment: .top) { videoAdBlockerToastOverlay }
        .overlay(alignment: .bottom) { translateBarOverlay }
    }

    // MARK: - Actions

    func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    func toggleBookmark() { b.toggleBookmark() }
    func inspectElement() { b.inspectElement() }

    func toggleDevTools() {
        showDevToolsPanel.toggle()
        b.toggleDevMode()
    }

    func loadHome(for tab: Tab) { b.loadHome(for: tab) }

    func navigateToURL(_ input: String, for tab: Tab) { b.navigateToURL(input, for: tab) }

    func showFindBar() {
        findString = ""
        findHasMatch = false
        findMatchCount = 0
        findCurrentIndex = 0
        isFindBarVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFindFocused = true
        }
    }

    func hideFindBar() {
        isFindBarVisible = false
        findString = ""
        findHasMatch = false
        findMatchCount = 0
        findCurrentIndex = 0
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

    func performFindAll() {
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
        tab.browser.webView.evaluateJavaScript(WebView.findCountJS(query: findString)) { value, _ in
            if let count = value as? Int {
                DispatchQueue.main.async {
                    findMatchCount = count
                }
            }
        }
    }

    func performFindNext() {
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

    func performFindPrevious() {
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

    func zoomTab(by delta: Double) { b.zoom(by: delta) }

    func zoomTab(to value: Double) { b.zoom(to: value) }

    func printPage() { b.printPage() }

    func startScreenshot() { b.startScreenshot(saveFolder: settings.screenshotFolder) }

    func refreshMediaQueries(for tab: Tab) { b.refreshMediaQueries(for: tab) { mediaQueries = $0 } }

    func captureResponsiveScreenshot(for tab: Tab) { b.captureResponsiveScreenshot(for: tab) }

    func captureFullPage() { b.captureFullPage() }

    func togglePictureInPicture() { b.togglePictureInPicture() }
}
