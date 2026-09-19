import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    let appState: AppState
    /// Persistent per-window session identity — carried by the window via
    /// the value-based WindowGroup and restored across launches. nil for a
    /// brand-new ⌘N window until onAppear mints one.
    @Binding var sessionID: UUID?

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
    /// Observed so the hidden shortcut buttons re-bind the moment a key is
    /// re-recorded in Settings (shared instance — see `SystemState`).
    @ObservedObject var shortcutStore: KeyboardShortcutStore
    /// Extracted business-logic coordinator. Replaces the ~25 action methods
    /// that previously lived on ContentView.
    @StateObject var b: BrowsingActions
    /// Per-window AI agent session. Its tool surface is bound to THIS
    /// window's TabManager (see `WindowToolSurface`), so the agent always
    /// acts on the window the chat lives in — not on whichever window was
    /// last key. Preferences and conversation history stay shared.
    @StateObject var aiSession: AgentSessionStore
    @FocusState var isUrlFocused: Bool
    @FocusState var isFindFocused: Bool
    @State var showTranslateBar = false
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.openWindow) var openWindow

    init(appState: AppState, sessionID: Binding<UUID?>) {
        self.appState = appState
        _sessionID = sessionID
        _shortcutStore = ObservedObject(wrappedValue: appState.system.keyboardShortcutStore)
        _bookmarkStore = ObservedObject(wrappedValue: appState.bookmarkStore)
        _passwordStore = ObservedObject(wrappedValue: appState.passwordStore)
        let tm = TabManager()
        _tabManager = StateObject(wrappedValue: tm)
        tm.onRequestWindowClose = { NSApp.keyWindow?.close() }
        _suggestionModel = StateObject(wrappedValue: AddressSuggestionsModel())
        _newTabSuggestionModel = StateObject(wrappedValue: AddressSuggestionsModel())
        _translationService = StateObject(wrappedValue: TranslationService())
        _responsiveDesignStore = StateObject(wrappedValue: ResponsiveDesignStore())
        _thumbnailStore = StateObject(wrappedValue: TabThumbnailStore())
        _aiSession = StateObject(wrappedValue: AgentSessionStore(
            preference: appState.aiPreference,
            conversationStore: appState.conversationStore
        ))
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
    var contentBlocker: ContentBlockerStore { appState.contentBlocker }
    /// OBSERVED so the password-save notice bar reacts to pendingSave.
    @ObservedObject var passwordStore: PasswordStore
    /// OBSERVED (unlike the accessors below): the toolbar's bookmark-star
    /// state is derived from this store's contents in `body` — without
    /// observing it, adding/removing a bookmark never re-rendered the
    /// toolbar and the star icon never moved.
    @ObservedObject var bookmarkStore: BookmarkStore
    var historyStore: HistoryStore { appState.historyStore }
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
                isFindBarVisible: $isFindBarVisible,
                showDownloads: Binding(
                    get: { appState.showDownloadsPanel },
                    set: { appState.showDownloadsPanel = $0 }
                )
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
                savePage: { savePage() },
                startScreenshot: { startScreenshot() },
                clearUrlFocus: { isUrlFocused = false }
            )
        )
    }

    @State var isAgentConfigured = false
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
    /// Brief action confirmation (bookmark added/removed, page saved, …)
    /// shown over the content area — silent actions read as broken ones.
    @State var actionToast: StatusBarToast?
    /// ⌘K command palette visibility (0.1.16).
    @State var showCommandPalette = false
    /// 标签拖出监视计时器（拖出窗口边界 → 撕出为新窗口）。
    @State var tearOutTimer: Timer?
    /// 更新检查器（更新横幅/手动检查共用）。
    @ObservedObject var updateChecker = UpdateChecker.shared

    /// Payload for the auto-dismissing action toast (icon + localized text).
    struct StatusBarToast: Equatable {
        let icon: String
        let text: String
    }
    @State var videoAdBlockerToast: String?
    @State var lastBlockedRuleId: UUID?
    @State var lastBlockedSelector = ""
    @State var lastBlockedXpath: String?
    @State var findString = ""
    @State var findHasMatch = false
    @State var findMatchCount = 0
    @State var findCurrentIndex = 0
    @State var isFullScreen = false
    @State var showAgentPanel = false
    @State private var hostingWindow: NSWindow?
    @State var aiFloatingPanel: AgentFloatingPanel?
    @State var showDevToolsPanel = false

    var body: some View {
        VStack(spacing: 0) {
            if let tab = tabManager.selectedTab {
                tabBarSection(for: tab)
                SelectedTabContent(
                    tab: tab, content: self, actions: b,
                    showSidebar: showSidebar,
                    showAgentPanel: $showAgentPanel,
                    showDevToolsPanel: showDevToolsPanel,
                    isFindBarVisible: isFindBarVisible,
                    onAskAI: { prompt in
                        aiSession.sendMessage(prompt)
                        showAgentPanel = true
                    }
                )
            }
        }
        .preferredColorScheme(settings.appearanceTheme == .system ? nil : settings.appearanceTheme == .dark ? .dark : .light)
        .tint(settings.accentColor.color)
        .ignoresSafeArea(.all, edges: .top)
        .background(WindowChromeGuard(onWindow: { hostingWindow = $0 }) {
            // This window just became key — record it as the
            // session-persistence target. (AI tools do NOT depend on this;
            // each window's AI session is pinned to its own TabManager.)
            appState.attach(tabManager: tabManager)
        })
        .onAppear {
            if aiFloatingPanel == nil {
                aiFloatingPanel = AgentFloatingPanel(store: aiSession, conversationStore: conversationStore)
            }
            if !isAgentConfigured {
                // Record this window as the session-persistence target, then
                // bind the AI agent to a surface pinned to THIS window's
                // TabManager (fixed — not the last-key-window pointer, which
                // is what made the floating AI panel act on the wrong
                // window). One `configure(with:)` call replaces the former
                // 13-parameter `configureStores`.
                appState.attach(tabManager: tabManager)
                aiSession.configure(with: WindowToolSurface(app: appState, tabManager: tabManager))
                isAgentConfigured = true
                StartupMetric.markFirstWindowInteractive()
            }
            if tabManager.tabs.isEmpty {
                // Bind this window to a persistent session identity (the
                // binding write is what SwiftUI persists for the window).
                if sessionID == nil { sessionID = UUID() }
                guard let sid = sessionID else { return }
                let sessionKey = TabSessionCoordinator.shared.sessionKey(for: sid)
                tabManager.sessionKey = sessionKey

                // 拖出接纳：本窗口由"标签拖出"创建，暂存区的标签直接吸收，
                // 不走会话恢复/新建流程。
                if let staged = TabTransfer.take(for: sid) {
                    tabManager.absorb(staged)
                    return
                }

                if tabManager.restoreSession(
                    forKey: sessionKey,
                    javaScriptEnabled: settings.isJavaScriptEnabled,
                    contentBlocker: contentBlocker,
                    videoAdBlocker: videoAdBlocker
                ) {
                    // This window's own tabs are back.
                } else if !appState.hasRestoredSession {
                    // First window with no own session. macOS 26 never
                    // persists SwiftUI window VALUES (no Saved Application
                    // State is written for SwiftUI scenes), so this window
                    // always arrives with a fresh UUID and its "own" session
                    // can never exist — without adoption, every launch
                    // opened blank despite a perfectly good saved session.
                    // Adopt the most recent session from the termination
                    // index (continue where you left off).
                    appState.hasRestoredSession = true
                    if settings.startupBehavior == .restoreSession,
                       let lastKey = TabSessionCoordinator.shared.mostRecentSessionKey(),
                       lastKey != sessionKey,
                       let session = TabSessionCoordinator.shared.session(forKey: lastKey),
                       !session.tabs.isEmpty {
                        // Re-bind the window to the adopted identity so all
                        // future persists land on the same session file.
                        tabManager.sessionKey = lastKey
                        tabManager.apply(
                            session: session,
                            javaScriptEnabled: settings.isJavaScriptEnabled,
                            contentBlocker: contentBlocker,
                            videoAdBlocker: videoAdBlocker
                        )
                        // Deliberately NOT pruning here: consuming the index
                        // would leave the next launch with nothing to adopt.
                        // This window now persists under `lastKey`, and the
                        // next clean quit rewrites the index with it.
                    } else {
                        TabSessionCoordinator.shared.pruneOrphanSessions(keeping: [sessionKey])
                        if let legacy = TabSessionCoordinator.shared.takeLegacySession() {
                            tabManager.apply(
                                session: legacy,
                                javaScriptEnabled: settings.isJavaScriptEnabled,
                                contentBlocker: contentBlocker,
                                videoAdBlocker: videoAdBlocker
                            )
                        } else {
                            b.openFreshTab()
                        }
                    }
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
            // The bus is app-wide: ⌘T/⌘W/⌘R… must act only in the KEY
            // window, not in every open window at once.
            guard hostingWindow === NSApp.keyWindow else { return }
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
        .overlay(alignment: .bottom) { actionToastOverlay }
        .overlay {
            if showCommandPalette {
                // Dimmed backdrop click = dismiss.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { showCommandPalette = false }
                CommandPalette { command in
                    commandDispatcher.handle(command)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 80)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) { screenshotToastOverlay }
        .overlay(alignment: .top) { videoAdBlockerToastOverlay }
        .overlay(alignment: .bottom) { translateBarOverlay }
    }

    // MARK: - Actions

    func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    func toggleBookmark() {
        guard let added = b.toggleBookmark() else { return }
        actionToast = StatusBarToast(
            icon: "bookmark.fill",
            text: added ? String(localized: "Bookmark Added") : String(localized: "Bookmark Removed")
        )
    }

    // MARK: - Profile switching (0.2.10)

    /// Switches this window's browsing persona. New tabs use the profile's
    /// isolated data store; existing tabs are NOT retroactively changed.
    func switchProfile(to profileID: UUID?) {
        tabManager.profileDataStore = ProfileStore.shared.dataStore(for: profileID)
    }

    // MARK: - 标签拖出/拖回（0.2.13 提前）

    /// 标签拖动开始：监视鼠标位置，拖出自窗口边界即撕出为新窗口。
    func beginTearOutWatch(for tab: Tab) {
        guard let window = hostingWindow else { return }
        let sourceFrame = window.frame.insetBy(dx: -16, dy: -16)
        let startLocation = NSEvent.mouseLocation
        tearOutTimer?.invalidate()
        // Timer 在主线程调度（Timer.scheduledTimer 默认当前 run loop），
        // 闭包直接同步执行即可，无需跨线程捕获。
        tearOutTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { timer in
            let mouse = NSEvent.mouseLocation
            // 已松手 → 放弃（落点没出窗口，保持原状）
            guard NSEvent.pressedMouseButtons & 1 == 1 else { timer.invalidate(); return }
            // 需要明显拖出（>60pt 位移且离开窗口），防误触
            guard hypot(mouse.x - startLocation.x, mouse.y - startLocation.y) > 60 else { return }
            guard !sourceFrame.contains(mouse) else { return }
            timer.invalidate()
            tearOut(tab: tab)
        }
    }

    /// 撕出：暂存标签 → 从本窗移除 → 开新窗口接纳。
    func tearOut(tab: Tab) {
        let newSessionID = UUID()
        guard let window = hostingWindow else { return }
        tabGroupStore.removeTabFromAll(tab.id)
        TabTransfer.stage(tab, for: newSessionID)
        tabManager.moveOut(tab)
        if tabManager.tabs.isEmpty {
            window.close()
        }
        openWindow(id: "main", value: newSessionID)
    }

    /// 拖回：把其他窗口的标签并入本窗口指定位置。
    func transferIn(fromSession sourceSession: UUID, tabID: UUID, index: Int?) {
        guard sourceSession != sessionID,
              let source = TabSessionCoordinator.shared.manager(forSession: sourceSession),
              let tab = source.tabs.first(where: { $0.id == tabID }) else { return }
        tabGroupStore.removeTabFromAll(tabID)
        source.moveOut(tab)
        if let index {
            tabManager.insert(tab, at: index)
            tabManager.selectTab(at: index)
        } else {
            tabManager.absorb(tab)
            tabManager.selectTab(at: tabManager.tabs.count - 1)
        }
    }

    /// ⌘S / File ▸ Save Page: captures the current page as a webarchive into
    /// the download folder, recorded as a completed download row.
    func savePage() {
        guard let tab = tabManager.selectedTab,
              let url = tab.browser.webView.url,
              !tab.isOnNewTabPage else { return }
        tab.browser.webView.createWebArchiveData { result in
            switch result {
            case .success(let data):
                let rawTitle = tab.browser.webView.title ?? tab.browser.pageTitle
                let sanitized = rawTitle
                    .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
                    .joined(separator: "-")
                    .trimmingCharacters(in: .whitespaces)
                let destination = self.downloadStore.uniqueURL(
                    for: (sanitized.isEmpty ? "page" : sanitized) + ".webarchive"
                )
                do {
                    try data.write(to: destination)
                    let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64)
                        ?? Int64(data.count)
                    self.downloadStore.add(item: DownloadItem(
                        id: UUID(), filename: destination.lastPathComponent, fileURL: destination,
                        totalBytes: size, downloadedBytes: size, state: .completed,
                        error: nil, cancel: nil, sourceURL: url
                    ))
                    self.actionToast = StatusBarToast(
                        icon: "arrow.down.doc.fill",
                        text: String(localized: "Page Saved")
                    )
                } catch {
                    self.actionToast = StatusBarToast(
                        icon: "exclamationmark.triangle.fill",
                        text: error.localizedDescription
                    )
                }
            case .failure(let error):
                self.actionToast = StatusBarToast(
                    icon: "exclamationmark.triangle.fill",
                    text: error.localizedDescription
                )
            }
        }
    }
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
