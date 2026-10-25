import AppKit
import Combine
import SwiftUI
import os
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    let appState: AppState
    /// Persistent per-window session identity — carried by the window via
    /// the value-based WindowGroup and restored across launches. nil for a
    /// brand-new ⌘N window until onAppear mints one.
    @Binding var sessionID: UUID?
    /// B1 激活自愈的补跑计数（v0.8.8；见 didBecomeActive 安全网）。
    @State private var restoreRepairCount = 0

    @StateObject var windowContext: WindowBrowsingContext
    /// 从保留的 windowContext（StateObject）派生——**不能**用 @ObservedObject 绑
    /// init 临时值：SwiftUI 会多次 init 本视图（sessionID 恢复、binding 变化），
    /// 每次 init 新建 context 会造出"渲染的 manager ≠ 恢复标签的 manager"的分裂
    ///（黑屏/初始页空白，2026-10-12）。观察经 windowContext 的 objectWillChange
    /// 转发（manager 变化 → context → 本视图）。
    var tabManager: TabManager { windowContext.tabManager }
    @StateObject var suggestionModel = AddressSuggestionsModel()
    /// The new-tab page's search box gets its OWN suggestion model — sharing
    /// one instance with the toolbar meant typing in either field repopulated
    /// the other's dropdown.
    @StateObject var newTabSuggestionModel = AddressSuggestionsModel()
    @StateObject var translationService = TranslationService()
    @StateObject var responsiveDesignStore = ResponsiveDesignStore()
    @StateObject var thumbnailStore = TabThumbnailStore()
    /// 球的交互状态**全局共享**（回到单例）：设置页/桥/独立 Agent 窗口都写
    /// AgentBallPanel.shared——per-window 实例会状态分裂（isExpanded 卡展开
    /// 态拖不动，2026-10-12）。overlay 每窗口一个挂载，但状态只有一份。
    @ObservedObject var ballPanel = AgentBallPanel.shared
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
    /// 地址栏是否正在编辑。**不用 `@FocusState`**：地址栏是 NSViewRepresentable
    /// 自己 becomeFirstResponder，SwiftUI 的 FocusState 不认，值永远停在 false
    /// （见 URLBarField 里的说明）。
    @State var isUrlFocused = false
    /// 地址栏的位置尺寸（Toolbar 实测、候选下拉按它对齐）。
    @State var urlFieldFrame: CGRect = .zero
    @FocusState var isFindFocused: Bool
    @State var showTranslateBar = false
    @Environment(\.scenePhase) var scenePhase
    /// 应用强调色：extension 里的 chrome（toast/通知条等）用它，见 AppAccent.swift。
    /// 不能是 `private`——`ContentView+Overlays.swift` 里的 extension 也要读。
    @Environment(\.appAccent) var appAccent: Color
    @Environment(\.openWindow) var openWindow
    @ObservedObject private var whatsNew = WhatsNewStore.shared
    @ObservedObject private var promotionShare = PromotionShareCenter.shared

    init(appState: AppState, sessionID: Binding<UUID?>) {
        let t0 = Date()
        defer {
            Log.app.info("launch phase: ContentView.init +\(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public)ms")
            LaunchAudit.mark("ContentView.init")
        }
        self.appState = appState
        _sessionID = sessionID
        let context = WindowBrowsingContext(windowID: sessionID.wrappedValue)
        _windowContext = StateObject(wrappedValue: context)
        // OBSERVED：body 直接读 settings.appearanceTheme/accentColor 等发布字段，
        // 普通计算属性不转发 objectWillChange——改主题/强调色的刷新此前靠
        // "恰好有别的重绘"（ARCH-4）。
        _settings = ObservedObject(wrappedValue: appState.settings)
        _siteSettingsStore = ObservedObject(wrappedValue: appState.siteSettingsStore)
        _shortcutStore = ObservedObject(wrappedValue: appState.system.keyboardShortcutStore)
        _bookmarkStore = ObservedObject(wrappedValue: appState.bookmarkStore)
        _passwordStore = ObservedObject(wrappedValue: appState.passwordStore)
        let tm = context.tabManager
        tm.onRequestWindowClose = { NSApp.keyWindow?.close() }
        _suggestionModel = StateObject(wrappedValue: AddressSuggestionsModel())
        _newTabSuggestionModel = StateObject(wrappedValue: AddressSuggestionsModel())
        _translationService = StateObject(wrappedValue: TranslationService())
        _responsiveDesignStore = StateObject(wrappedValue: ResponsiveDesignStore())
        _thumbnailStore = StateObject(wrappedValue: {
            let store = TabThumbnailStore()
            return store
        }())
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
            videoAdBlocker: appState.videoAdBlocker,
            downloadStore: appState.downloadStore
        ))
    }

    // Convenience accessors for shared stores
    /// OBSERVED（init 里从 appState 装配）：body 读它的发布字段。
    @ObservedObject var settings: Settings
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
    /// OBSERVED（工具栏菜单的"站点自动播放/暗色"勾选态从它派生，切换要
    /// 立即重绘——惰性计算属性不建立依赖，图标会停在旧态直到下次重绘）。
    @ObservedObject var siteSettingsStore: SiteSettingsStore
    /// OBSERVED：工具栏菜单的"双语对照"勾选态从它派生（同 siteSettingsStore
    /// 的理由——切换/进度要立即重绘）。
    @ObservedObject var bilingualService: BilingualReadingService = .shared
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
            siteSettingsStore: appState.siteSettingsStore,
            historyStore: historyStore,
            openSettings: { openWindow(id: "settings") },
            toggleWhiteboard: { WhiteboardPanel.shared.toggle() },
            toggleAgentBall: {
                ballPanel.toggle()
            },
            bindings: .init(
                showHistory: $showHistory,
                showWorkflows: $showWorkflows,
                showActivity: $showActivity,
                showBookmarks: $showBookmarks,
                showPlugins: $showPlugins,
                showElementBlock: $showElementBlock,
                showPasswordManager: $showPasswordManager,
                showAdBlockStats: $showAdBlockStats,
                showTabSwitcher: $showTabSwitcher,
                showSidebar: $showSidebar,
                isFindBarVisible: $isFindBarVisible,
                showWorkspaces: Binding(
                    get: { appState.showWorkspacesPanel },
                    set: { appState.showWorkspacesPanel = $0 }
                ),
                showSearchEverywhere: Binding(
                    get: { appState.showSearchEverywhere },
                    set: { appState.showSearchEverywhere = $0 }
                ),
                showReadingList: $showReadingList,
                showCommandPalette: $showCommandPalette,
                showAgentPanel: $showAgentPanel,
                showTabOverview: $showTabOverview
            ),
            actions: .init(
                newWindow: {
                    // Open a native SwiftUI window via the id'd WindowGroup.
                    // Each window gets its own ContentView (and TabManager),
                    // sharing the global AppState. Replaces the manual
                    // NSHostingView+NSWindow approach so window lifecycle,
                    // state restoration, and standard chrome are handled by
                    // SwiftUI. See docs/ARCHITECTURE.md (L2 multi-window).
                    // 带值组的 openWindow 有两个坑（2026-10-05 E2E 实测）：
                    // ① 必须用 id:value: 重载——id 单参重载对 WindowGroup(for:)
                    //    静默 no-op；② value 不能传 nil——nil 是 no-op 语义，
                    //    传真 UUID 直达新会话（等价 onAppear 的 mint 路径）。
                    openWindow(id: "main", value: UUID())
                },
                toggleBookmark: { toggleBookmark() },
                toggleFullScreen: { toggleFullScreen() },
                showFindBar: { showFindBar() },
                hideFindBar: { hideFindBar() },
                printPage: { printPage() },
                savePage: { savePage() },
                startScreenshot: { startScreenshot() },
                toggleDevTools: { toggleDevTools() },
                captureFullPage: { captureFullPage() },
                focusUrlBar: { focusUrlBar() },
                openFile: { openFileInNewTab() },
                closeWindow: { hostingWindow?.close() },
                findNext: { performFindNext() },
                findPrevious: { performFindPrevious() },
                addToReadingList: { addToReadingList() },
                askAgentAboutPage: { askAgentAboutPage() },
                clearUrlFocus: { isUrlFocused = false }
            )
        )
    }

    @State var isAgentConfigured = false
    @State var isFindBarVisible = false
    @State var showHistory = false
    @State var showWorkflows = false
    @State var showActivity = false
    @State var showBookmarks = false
    @State var showPlugins = false
    @State var showReadingList = false
    @State var showTabSwitcher = false
    /// 全窗口标签概览（0.2.19）：Safari ⇧⌘\ 式缩略图网格。
    @State var showTabOverview = false
    @State var showSidebar = false
    @State var showElementBlock = false
    @State var showAdBlockStats = false
    @State var showPasswordManager = false
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
    @State var autoAdCleanToast: String?
    @State var dppEventToast: (host: String, event: String)?
    @State var lastBlockedRuleId: UUID?
    @State var lastBlockedSelector = ""
    @State var lastBlockedXpath: String?
    @State var findString = ""
    @State var findHasMatch = false
    @State var findMatchCount = 0
    @State var findCurrentIndex = 0
    /// 查找大小写敏感（粘性偏好；@AppStorage 直接持久化）。
    @AppStorage("findCaseSensitive") var findCaseSensitive = false
    /// 首个命中的上下文片段（±40 字符；查找栏预览行）。
    @State var findSnippet = ""
    /// 原生窗口全屏（⌃⌘F）：只影响标签栏给红绿灯留的边距（全屏时红绿灯
    /// 浮在内容上），**不再收起 chrome**——全屏浏览没有标签栏没法用。
    @State var isWindowFullScreen = false
    /// 站点视频/元素全屏：WebKit 自建的整屏窗口（`WebCoreFullScreenWindow`）
    /// 盖住整屏，此时才收起 chrome。与窗口全屏是两件事，必须分开判：
    /// 前者是"视频占满屏幕"，后者是"窗口占满屏幕、但还要能切标签"。
    @State var isSiteFullScreen = false
    @State var showAgentPanel = false
    @State private var hostingWindow: NSWindow?
    @State var aiFloatingPanel: AgentFloatingPanel?
    @State var showDevToolsPanel = false

    /// 主列（0.6.3）：原 body 的整列内容——垂直标签栏模式下作为 HSplitView
    /// 的右栏（见 body）。
    @ViewBuilder
    var mainStack: some View {
        VStack(spacing: 0) {
            if let tab = tabManager.selectedTab {
                // 只有**站点自己发起的整屏**（视频/元素全屏）才收掉标签栏与
                // 工具栏——那是 WebKit 的整屏窗口在盖屏。原生窗口全屏（⌃⌘F）
                // 保持 chrome 可见：全屏浏览不能切标签等于没法用。
                if !isSiteFullScreen && !settings.verticalTabBar {
                    tabBarSection(for: tab)
                }
                SelectedTabContent(
                    tab: tab, content: self, actions: b,
                    showSidebar: showSidebar,
                    showAgentPanel: $showAgentPanel,
                    showDevToolsPanel: showDevToolsPanel,
                    isFindBarVisible: isFindBarVisible,
                    isFullScreen: isSiteFullScreen,
                    onAskAI: { prompt in
                        aiSession.sendMessage(prompt)
                        showAgentPanel = true
                        // 登记键统一用 sessionKey（"session-<uuid>"）——通知
                        // 深链（NotificationRouter）按这个键读；此前写裸 UUID
                        // 读取永远落空（面板已开还会被再 toggle 一次关掉）。
                        AgentPanelVisibilityStore.shared.record(key: tabManager.sessionKey, shown: true)
                    }
                )
                .overlay {
                    // 标签概览（0.2.19）：盖住内容区，工具栏保持可见。
                    if showTabOverview {
                        TabOverviewView(
                            tabManager: tabManager,
                            accentColor: settings.accentColor.color,
                            content: self,
                            onSelectTab: { index in
                                isUrlFocused = false
                                tabManager.selectTab(at: index)
                            },
                            onCloseTab: { index in
                                tabManager.closeTab(at: index)
                            },
                            onAddTab: {
                                tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: settings.autoPlayPolicy, newTabPosition: settings.newTabPosition)
                            },
                            onClose: { showTabOverview = false }
                        )
                        .transition(.opacity)
                    }
                }
                .animation(.layoutSpring, value: showTabOverview)
            }
        }
        .preferredColorScheme(settings.appearanceTheme == .system ? nil : settings.appearanceTheme == .dark ? .dark : .light)
        .appAccent(settings.accentColor.color)
        .overlay {
            // 悬浮球：窗口内覆盖层（真液态玻璃；位置/展开状态自管理）
            if ballPanel.isEnabled {
                AgentBallOverlay(state: ballPanel)
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .background(WindowChromeGuard(onWindow: { hostingWindow = $0 }) {
            // This window just became key — record it as the
            // session-persistence target. (AI tools do NOT depend on this;
            // each window's AI session is pinned to its own TabManager.)
            appState.attach(tabManager: tabManager)
        })
        .onAppear {
            // 首窗相位（0.6.4 启动分段第三拍；每个窗口都会打，首条即首窗）。
            Log.app.info("launch phase: first window content appeared +\(Int(Date().timeIntervalSince(DesireApp.launchStart) * 1000), privacy: .public)ms")
            LaunchAudit.mark("first window")
            LaunchAudit.summarize()
            // 后台标签页缩略图轮捕的 tab 源（hover 预览秒开，见 TabThumbnailStore）。
            thumbnailStore.setTabsProvider { [tabManager] in tabManager.tabs }
            if aiFloatingPanel == nil {
                aiFloatingPanel = AgentFloatingPanel(
                    store: aiSession,
                    conversationStore: conversationStore,
                    accentColor: settings.accentColor.color
                )
            }
            let ball = ballPanel
            ball.onOpenAgentPanel = {
                showAgentPanel = true
                AgentPanelVisibilityStore.shared.record(key: tabManager.sessionKey, shown: true)
            }
            ball.onAskAboutPage = { askAgentAboutPage() }
            // v4：翻译/自定义提示词/拖拽投递的通用发话口 + 截图槽位。
            ball.onSendPrompt = { text in
                aiSession.sendMessage(text)
                showAgentPanel = true
            }
            ball.onScreenshot = { startScreenshot() }
            ball.onPageFullscreen = { [tabManager] in
                tabManager.selectedTab?.browser.webView.fullscreenState == .inFullscreen
            }
            // v5：触盘菜单头的页面上下文（favicon + 标题）。
            ball.pageContextProvider = { [tabManager] in
                guard let tab = tabManager.selectedTab else { return nil }
                let title = tab.displayTitle.trimmingCharacters(in: .whitespaces)
                return .init(title: title.isEmpty ? "新标签页" : title,
                             urlString: tab.urlString)
            }
            // v7：特色快捷动作的操作对象（AI 去广告/视频下载以选中标签为目标）。
            ball.pageTabProvider = { [tabManager] in
                tabManager.selectedTab
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
            restoreSessionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // B1 安全网（v0.8.8）：锁屏/未激活状态下启动时，首窗内容可能
            // 从未构建（WKWebView/窗口渲染在未激活进程不跑）——onAppear 的
            // 恢复编排整段没执行，窗口停在零标签。应用真正活动化后重跑。
            // 排除 isTerminating（终止流程补发事件的既有坑同源）；最多 3 次
            // 防止与"用户手动关光标签"打架（关最后一标签默认连窗关，只剩
            // 理论边界）。
            guard !TabSessionCoordinator.shared.isTerminatingNow,
                  restoreRepairCount < 3 else { return }
            guard tabManager.tabs.isEmpty else { return }
            restoreRepairCount += 1
            Log.app.info("session restore re-run on activation (attempt \(self.restoreRepairCount, privacy: .public))")
            restoreSessionIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                // App hidden/terminated: force a full re-archive so the blob
                // on disk reflects the final state, not the last fingerprint
                // hit.
                tabManager.persistSession(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWebApp)) { note in
            // 桥/深链打开 App Mode 窗口（openWindow 只在视图环境里可用）。
            if let raw = note.userInfo?["id"] as? String,
               let id = UUID(uuidString: raw) {
                openWindow(id: "webapp", value: id)
            }
        }
        .task {
            // 更新后 What's New：单个窗口认领（--automation 下自动跳过）。
            try? await Task.sleep(for: .milliseconds(700))
            WhatsNewStore.shared.presentIfNeeded()
        }
        .sheet(isPresented: $whatsNew.isPresented) {
            WhatsNewSheet(sync: appState.syncStore)
        }
        .sheet(isPresented: $promotionShare.isPresented) {
            PromotionShareSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            if Self.isSiteFullscreenWindow(window, hosting: hostingWindow) {
                isSiteFullScreen = true
            } else if window === hostingWindow {
                isWindowFullScreen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            if Self.isSiteFullscreenWindow(window, hosting: hostingWindow) {
                isSiteFullScreen = false
            } else if window === hostingWindow {
                isWindowFullScreen = false
            }
        }
        // Agent 任务中途提问（askUser）时自动弹出面板 —— 提问卡片只存在于面板里，
        // 面板没开时用户根本看不见，回合会无限挂起（已开则不动，避免误关）。
        .onReceive(aiSession.promptCenter.$pending) { pending in
            if pending != nil, !showAgentPanel {
                showAgentPanel = true
                AgentPanelVisibilityStore.shared.record(key: tabManager.sessionKey, shown: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // 多窗口联动：deliveryTarget 跟随 key window——此前只有
            // "最新创建者接管"，切回旧窗后语音/定时/无 window 桥调用仍会
            // 打到新窗的会话（0.6.2 验收抓到）。
            guard note.object as? NSWindow === hostingWindow else { return }
            AgentScheduler.shared.deliveryTarget = aiSession
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // 本窗口即将关闭：把它的 TabManager 从协调器摘掉——否则僵尸
            // manager 会在退出时把已关窗口的会话写回 session-index，下次
            // 启动多还一扇窗（2026-10-15 实测，见 unregister 注释）。
            guard note.object as? NSWindow === hostingWindow else { return }
            TabSessionCoordinator.shared.unregister(tabManager)
            // 投递目标若正是本窗口的会话，转交给还在世的会话——否则后续回合
            // 的工具会继续打到这扇已关的窗口上（实测：点击/导航静默失效）。
            AgentScheduler.shared.sessionDidClose(aiSession)
        }
        .onReceive(CommandBus.shared.publisher) { command in
            // The bus is app-wide: ⌘T/⌘W/⌘R… must act only in the KEY
            // window, not in every open window at once.
            guard hostingWindow === NSApp.keyWindow else { return }
            commandDispatcher.handle(command)
        }
        .onReceive(NotificationCenter.default.publisher(for: .desireCloseWindow)) { note in
            // 只关**该会话所在的窗口**（工具按会话点名；后台挂起窗口也能关）。
            guard let wanted = note.userInfo?["session"] as? String,
                  let mine = AgentScheduler.shared.liveSessions()
                      .first(where: { $0.store === aiSession })?.id.uuidString,
                  wanted == mine else { return }
            hostingWindow?.close()
        }
        .onReceive(NotificationCenter.default.publisher(for: .desireOpenNewWindow)) { note in
            // 只让**该会话所在的窗口**开新窗（工具按会话点名；应用后台也可用，
            // 不经过 CommandBus 的 key-window 守卫）。
            guard let wanted = note.userInfo?["session"] as? String,
                  let mine = AgentScheduler.shared.liveSessions()
                      .first(where: { $0.store === aiSession })?.id.uuidString,
                  wanted == mine else { return }
            openWindow(id: "main", value: UUID())
        }
        .onReceive(NotificationCenter.default.publisher(for: .desireShowAgentPanel)) { note in
            // 菜单栏快速入口（v19）：亮出 Agent 面板。不能走 CommandBus——
            // 弹窗打开时它自己是 key window，上面的 key 守卫会把命令丢掉。
            // **显式点名会话**（DevTools 检查器试跑，v0.7.19）：只在该会话所在
            // 窗口亮；缺省按"持有投递目标会话"收敛到唯一窗口（首窗接管）。
            if let wanted = note.userInfo?["session"] as? String {
                let mine = AgentScheduler.shared.liveSessions()
                    .first(where: { $0.store === aiSession })?.id.uuidString
                guard mine == wanted else { return }
            } else {
                let target = AgentScheduler.shared.deliveryTarget
                guard target == nil || aiSession === target else { return }
            }
            showAgentPanel = true
            AgentPanelVisibilityStore.shared.record(key: tabManager.sessionKey, shown: true)
            hostingWindow?.makeKeyAndOrderFront(nil)
            Log.agent.info("menu bar quick entry: panel shown in window \(sessionID?.uuidString ?? "-", privacy: .public)")
        }
        .onChange(of: tabManager.selectedTab?.id) { _, _ in
            // 阅读进度：切走前先把旧标签采一次（换表后就没机会了），再换跟踪对象。
            ReadingProgressTracker.shared.captureNow()
            ReadingProgressTracker.shared.track(tab: tabManager.selectedTab)
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
            passwordStore: passwordStore,
            pluginStore: pluginStore,
            tabManager: tabManager,
            videoAdBlocker: videoAdBlocker,
            profileDataStore: tabManager.profileDataStore,
            contentBlockerStore: contentBlocker,
            agentSession: aiSession,
            onOpenAgentPanel: {
                showAgentPanel = true
                appState.showSearchEverywhere = false
            },
            historyStoreRef: historyStore,
            bookmarkStoreRef: bookmarkStore,
            readingListStoreRef: readingListStore,
            showHistory: $showHistory,
            showWorkflows: $showWorkflows,
            showActivity: $showActivity,
            showBookmarks: $showBookmarks,
            showSearchHistory: $showSearchHistory,
            showPlugins: $showPlugins,
            showReadingList: $showReadingList,
            showElementBlock: $showElementBlock,
            showAdBlockStats: $showAdBlockStats,
            showPasswordManager: $showPasswordManager,
            showWorkspacesPanel: Binding(
                get: { appState.showWorkspacesPanel },
                set: { appState.showWorkspacesPanel = $0 }
            ),
            showSearchEverywhere: Binding(
                get: { appState.showSearchEverywhere },
                set: { appState.showSearchEverywhere = $0 }
            ),
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
                CommandPalette(
                    makeSources: { makePaletteSources() },
                    onRun: { command in
                        commandDispatcher.handle(command)
                    },
                    onActivate: { row, newTab in
                        activatePaletteRow(row, newTab: newTab)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 80)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) { screenshotToastOverlay }
        .overlay(alignment: .top) { videoAdBlockerToastOverlay }
        .overlay(alignment: .top) { autoAdCleanToastOverlay }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("autoAdCleanBlocked"))) { note in
            guard let host = note.userInfo?["host"] as? String,
                  let count = note.userInfo?["count"] as? Int else { return }
            autoAdCleanToast = String(localized: "AI auto-blocked \(count) element(s) on \(host)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if autoAdCleanToast?.contains(host) == true { autoAdCleanToast = nil }
            }
        }
        .overlay(alignment: .top) { dppEventToastOverlay }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("dppEventSuppressed"))) { note in
            guard let host = note.userInfo?["host"] as? String,
                  let event = note.userInfo?["event"] as? String else { return }
            // 引导（用户要求）：站点支持 DPP 事件但被默认档拦下 → 给一键开启，
            // 点完立刻生效（本站 draft 档），不用去设置翻。
            dppEventToast = (host: host, event: event)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if dppEventToast?.host == host { dppEventToast = nil }
            }
        }
        .overlay(alignment: .bottom) { translateBarOverlay }
    }

    /// body 壳（0.6.3）：垂直标签栏开启且非站点整屏时，侧栏与主列并排
    /// （HSplitView 分隔条可拖，宽度由 VerticalTabBarView 的 AppStorage 持久化）；
    /// 其余情况维持顶部标签栏形态。
    var body: some View {
        if settings.verticalTabBar && !isSiteFullScreen {
            HSplitView {
                VerticalTabBarView(
                    tabManager: tabManager,
                    tabGroupStore: tabGroupStore,
                    settings: settings,
                    selectedIndex: tabManager.selectedIndex,
                    isFullScreen: isWindowFullScreen,
                    onSelectTab: { index in
                        isUrlFocused = false
                        tabManager.selectTab(at: index)
                    },
                    onCloseTab: { index in
                        let tabId = tabManager.tabs[index].id
                        thumbnailStore.clearThumbnail(for: tabId)
                        tabManager.closeTab(at: index)
                    },
                    onMoveTab: { tabManager.moveTab(from: $0, to: $1) },
                    onReloadTab: { $0.browser.webView.reload() },
                    onCopyTabURL: { tab in
                        if let url = tab.browser.webView.url {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    },
                    onToggleAudioMute: { index in
                        tabManager.tabs[index].audioMuted.toggle()
                    },
                    onTogglePin: { index in
                        tabManager.tabs[index].isPinned.toggle()
                    },
                    onCloseOtherTabs: { index in
                        let keptId = tabManager.tabs[index].id
                        for t in tabManager.tabs where t.id != keptId {
                            thumbnailStore.clearThumbnail(for: t.id)
                        }
                        tabManager.closeOthers(keeping: index)
                    },
                    onCloseTabsToRight: { index in
                        for i in (index + 1..<tabManager.tabs.count) {
                            thumbnailStore.clearThumbnail(for: tabManager.tabs[i].id)
                        }
                        tabManager.closeToTheRight(of: index)
                    },
                    onRemoveFromGroup: { tabGroupStore.removeTabFromAll($0) },
                    tabGroups: tabGroupStore.groups,
                    onToggleGroupCollapse: { tabGroupStore.toggleCollapsed($0) },
                    onDeleteGroup: { tabGroupStore.delete($0) },
                    onAddToGroup: { tabId, groupId in tabGroupStore.addTab(tabId, to: groupId) },
                    onRenameGroup: { id, name in tabGroupStore.rename(id, to: name) },
                    onCreateGroup: { index in createGroupFromTab(index) },
                    tabGroupColor: { [gColors = [Color.red, .orange, .yellow, .green, .blue, .purple, .pink, .brown]] tabId in
                        tabGroupStore.group(for: tabId).map { gColors[$0.colorIndex % gColors.count] }
                    }
                )
                .frame(maxHeight: .infinity)
                mainStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            mainStack
        }
    }

    // MARK: - Actions

    /// 通知里那个窗口是不是"站点整屏窗口"（WebKit 为视频/元素全屏自建的
    /// 窗口）。宿主窗口还没拿到时退回类名判断——两者都不是我们的窗口。
    static func isSiteFullscreenWindow(_ window: NSWindow, hosting: NSWindow?) -> Bool {
        if let hosting { return window !== hosting }
        return String(describing: type(of: window)).contains("WebCoreFullScreenWindow")
    }

    func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    /// File ▸ Open Location (⌘L)：聚焦地址栏并全选。
    func focusUrlBar() {
        isUrlFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: URLBarField.selectAllNotification, object: nil)
        }
    }

    /// File ▸ Open File… (⌘O)：本地文件在新标签打开（沙盒下 NSOpenPanel
    /// 授予的 URL 可读）。
    func openFileInNewTab() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open File")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // R2-15：sheet 异步（runModal 冻结整个 app）。
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            tabManager.addTab(
                url: url.absoluteString,
                javaScriptEnabled: settings.isJavaScriptEnabled,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker,
                autoPlayPolicy: settings.autoPlayPolicy,
                newTabPosition: settings.newTabPosition
            )
        }
    }

    /// Bookmarks ▸ Add to Reading List：当前页入阅读列表（去重）。
    func addToReadingList() {
        guard let tab = tabManager.selectedTab,
              let url = tab.browser.webView.url?.absoluteString ?? (tab.urlString.isEmpty ? nil : tab.urlString),
              !tab.isOnNewTabPage else { return }
        let title = tab.browser.pageTitle.isEmpty ? url : tab.browser.pageTitle
        if !readingListStore.items.contains(where: { $0.url == url }) {
            readingListStore.add(title: title, url: url)
        }
        withAnimation(.overlaySpring) { actionToast = StatusBarToast(
            icon: "book.read",
            text: String(localized: "Added to Reading List")
        ) }
    }

    /// Agent ▸ Ask About This Page (⌘⇧A)：让活动会话的 Agent 阅读并
    /// 总结当前页面。
    func askAgentAboutPage() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let url = tab.browser.webView.url?.absoluteString ?? tab.urlString
        aiSession.sendMessage("请阅读当前页面（\(url)）并总结要点。")
        showAgentPanel = true
    }

    func toggleBookmark() {
        guard let added = b.toggleBookmark() else { return }
        withAnimation(.overlaySpring) { actionToast = StatusBarToast(
            icon: "bookmark.fill",
            text: added ? String(localized: "Bookmark Added") : String(localized: "Bookmark Removed")
        ) }
    }

    // MARK: - Profile switching (0.2.10)

    /// Switches this window's browsing persona. New tabs use the profile's
    /// isolated data store; existing tabs are NOT retroactively changed.
    func switchProfile(to profileID: UUID?) {
        windowContext.setProfile(profileID)
        appState.applyProfile(profileID)
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
        b.savePage(for: tabManager.selectedTab) { outcome in
            switch outcome {
            case .saved:
                self.actionToast = StatusBarToast(
                    icon: "arrow.down.doc.fill",
                    text: String(localized: "Page Saved")
                )
            case .failed(let message):
                self.actionToast = StatusBarToast(
                    icon: "exclamationmark.triangle.fill",
                    text: message
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

    /// 会话恢复编排入口（onAppear 与激活自愈共用；v0.8.8 从 onAppear 抽出）。
    /// 零标签窗口才动作——SessionRestore 内部各分支幂等（本窗口会话恢复/
    /// 采纳最近会话/兜底新标签），重复调用不会重复开页。
    private func restoreSessionIfNeeded() {
        guard tabManager.tabs.isEmpty else { return }
        if sessionID == nil { sessionID = UUID() }
        if let restored = SessionRestore.run(
            for: tabManager,
            context: .init(
                tabManager: tabManager,
                appState: appState,
                settings: settings,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker,
                existingSessionID: sessionID,
                onStartupNotice: { message in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        actionToast = StatusBarToast(
                            icon: "arrow.counterclockwise.circle",
                            text: message
                        )
                    }
                },
                openFreshTab: { b.openFreshTab() },
                openStartupURLs: { urls in
                    // 启动页集/主页（v0.7.19）：逐个开标签，末条自然成为选中。
                    for url in urls {
                        tabManager.addTab(
                            url: url,
                            incognito: false,
                            javaScriptEnabled: settings.isJavaScriptEnabled,
                            contentBlocker: contentBlocker,
                            videoAdBlocker: videoAdBlocker,
                            autoPlayPolicy: settings.autoPlayPolicy,
                            newTabPosition: .end
                        )
                    }
                },
                openWindowForRestore: {
                    // 崩溃多窗口恢复：新窗带全新 UUID，由 SessionRestore
                    // 认领 pending key（不是这个 UUID 自己的会话）。
                    openWindow(id: "main", value: UUID())
                }
            )
        ) {
            sessionID = restored.sessionID
            windowContext.sessionKey = restored.sessionKey
        }
    }

    func navigateToURL(_ input: String, for tab: Tab) { b.navigateToURL(input, for: tab) }

    func showFindBar() {
        findString = ""
        findSnippet = ""
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
        findSnippet = ""
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
            findSnippet = ""
            return
        }
        let config = WKFindConfiguration()
        config.wraps = false
        config.caseSensitive = findCaseSensitive
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
            if result.matchFound {
                findCurrentIndex = 0
            }
        }
        tab.browser.webView.evaluateJavaScript(
            WebView.findCountJS(query: findString, caseSensitive: findCaseSensitive)) { value, _ in
            if let count = value as? Int {
                DispatchQueue.main.async {
                    findMatchCount = count
                }
            }
        }
        tab.browser.webView.evaluateJavaScript(
            WebView.findSnippetJS(query: findString, caseSensitive: findCaseSensitive)) { value, _ in
            DispatchQueue.main.async {
                findSnippet = (value as? String) ?? ""
            }
        }
    }

    func performFindNext() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.wraps = true
        config.caseSensitive = findCaseSensitive
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
        config.caseSensitive = findCaseSensitive
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
