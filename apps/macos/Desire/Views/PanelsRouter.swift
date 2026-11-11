import SwiftUI
import WebKit

/// Presents the app's modal panels: history, bookmarks, search history,
/// extensions, reading list, element blocker, and the plugins window
/// trigger. Extracted from `ContentView.body` (roadmap L1-1) — one modifier
/// instead of six inline sheet blocks.
///
/// Stores are plain `let` references (closures read them live at callback
/// time); panel visibility comes in as bindings owned by `ContentView`.
struct PanelsRouter: ViewModifier {
    /// 工作区/归档"开新窗"需要（v0.8.52 批 3）。
    @Environment(\.openWindow) private var openWindow
    let settings: Settings
    let historyStore: HistoryStore
    let bookmarkStore: BookmarkStore
    let searchHistoryStore: SearchHistoryStore
    let readingListStore: ReadingListStore
    let elementBlockStore: ElementBlockStore
    let passwordStore: PasswordStore
    let pluginStore: PluginStore
    let tabManager: TabManager
    let videoAdBlocker: VideoAdBlocker
    let profileDataStore: WKWebsiteDataStore?
    let contentBlockerStore: ContentBlockerStore
    let agentSession: AgentSessionStore
    let onOpenAgentPanel: () -> Void
    let historyStoreRef: HistoryStore
    let bookmarkStoreRef: BookmarkStore
    let readingListStoreRef: ReadingListStore
    @Binding var showHistory: Bool
    @Binding var showWorkflows: Bool
    @Binding var showActivity: Bool
    @Binding var showBookmarks: Bool
    @Binding var showSearchHistory: Bool
    @Binding var showPlugins: Bool
    @Binding var showReadingList: Bool
    @Binding var showElementBlock: Bool
    @Binding var showAdBlockStats: Bool
    @Binding var showPasswordManager: Bool
    @Binding var showWorkspacesPanel: Bool
    @Binding var showSearchEverywhere: Bool
    @Binding var showClipboardHistory: Bool

    /// Navigates the selected tab (panel selection callbacks).
    let onNavigate: (String) -> Void
    /// Kicks off the element picker for the selected tab.
    let onStartElementPicker: () -> Void
    let onDeleteBookmark: (Bookmark) -> Void

    /// 其他窗口的标签（v0.8.40 跨窗口标签搜索）。
    private var foreignTabItems: [SearchEverywhere.Item] {
        TabSessionCoordinator.shared.liveManagers()
            .filter { $0 !== tabManager }
            .flatMap { manager -> [SearchEverywhere.Item] in
                guard let key = manager.sessionKey, !key.isEmpty else { return [] }
                return manager.tabs.map { tab in
                    SearchEverywhere.Item(
                        source: .tab,
                        id: "foreign:\(key)|\(tab.id.uuidString)",
                        title: tab.displayTitle,
                        url: tab.browser.webView.url?.absoluteString ?? tab.urlString)
                }
            }
    }

    private func activateForeignTab(_ raw: String) {
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let manager = TabSessionCoordinator.shared.liveManagers()
                .first(where: { $0.sessionKey == parts[0] }),
              let tabID = UUID(uuidString: parts[1]),
              let index = manager.tabs.firstIndex(where: { $0.id == tabID })
        else { return }
        TabSessionCoordinator.shared.setActive(manager)
        manager.selectTab(at: index)
        manager.selectedTab?.browser.webView.window?.makeKeyAndOrderFront(nil)
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showHistory) {
                HistoryPanel(store: historyStore, onSelect: { url in
                    showHistory = false
                    onNavigate(url)
                }, onClose: { showHistory = false })
            }
            .sheet(isPresented: $showWorkflows) {
                WorkflowPanel(onClose: { showWorkflows = false })
            }
            .sheet(isPresented: $showActivity) {
                ActivityPanel(onClose: { showActivity = false })
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarkPanel(store: bookmarkStore, onSelect: { url in
                    showBookmarks = false
                    onNavigate(url)
                }, onDelete: onDeleteBookmark, onClose: { showBookmarks = false })
            }
            .sheet(isPresented: $showSearchHistory) {
                SearchHistoryPanel(store: searchHistoryStore, onSelect: { query in
                    showSearchHistory = false
                    let url = settings.searchURLTemplate
                        + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? query)
                    onNavigate(url)
                }, onClose: { showSearchHistory = false })
            }
            .onChange(of: showPlugins) { _, isShown in
                guard isShown else { return }
                showPlugins = false
                PluginsWindowController.shared.show(pluginStore: pluginStore)
            }            .sheet(isPresented: $showReadingList) {
                ReadingListPanel(store: readingListStore, onSelect: { url in
                    showReadingList = false
                    onNavigate(url)
                }, onClose: { showReadingList = false })
            }
            .sheet(isPresented: $showElementBlock) {
                ElementBlockPanel(store: elementBlockStore, onStartPicker: onStartElementPicker, onClose: { showElementBlock = false })
            }
            .sheet(isPresented: $showAdBlockStats) {
                AdBlockPanel()
            }
            .sheet(isPresented: $showPasswordManager) {
                PasswordPanel(passwordStore: passwordStore)
            }
            .sheet(isPresented: $showClipboardHistory) {
                ClipboardHistoryPanel()
            }
            .sheet(isPresented: $showSearchEverywhere) {
                SearchEverywherePanel(
                    tabManager: tabManager,
                    historyStore: historyStoreRef,
                    bookmarkStore: bookmarkStoreRef,
                    readingListStore: readingListStoreRef,
                    settings: settings,
                    contentBlocker: contentBlockerStore,
                    videoAdBlocker: videoAdBlocker,
                    agentSession: agentSession,
                    onClose: { showSearchEverywhere = false },
                    onOpenAgentPanel: onOpenAgentPanel,
                    foreignTabItems: foreignTabItems,
                    onActivateForeignTab: activateForeignTab
                )
            }
            .sheet(isPresented: $showWorkspacesPanel) {
                WorkspacePanel(
                    tabManager: tabManager,
                    settings: settings,
                    contentBlocker: contentBlockerStore,
                    videoAdBlocker: videoAdBlocker,
                    profileDataStore: profileDataStore,
                    onClose: { showWorkspacesPanel = false },
                    onOpenWorkspaceInNewWindow: { workspace in
                        if let id = ClosedWindowRestorer.stage(session: workspace.session,
                                                               frame: workspace.frame) {
                            openWindow(id: "main", value: id)
                        }
                    },
                    onOpenArchivedInNewWindow: { entry in
                        guard let session = TabSessionCoordinator.shared
                            .archivedSession(named: entry.fileName),
                              let id = ClosedWindowRestorer.stage(session: session,
                                                                  frame: nil) else { return }
                        openWindow(id: "main", value: id)
                    }
                )
            }
    }
}
