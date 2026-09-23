import Foundation

/// The slice of app state that AI browser tools operate over.
///
/// Replaces the 13 individually-injected `weak var` stores on
/// `BrowserToolProvider` (and the matching 13-parameter `configureStores`)
/// with a single protocol boundary. The agent's tool provider holds one
/// `weak var surface` and resolves each tool's target via the protocol.
/// Adding a new store that tools can address is now a one-line protocol
/// addition + conformance, not a 3-file edit.
///
/// Conformed to by `WindowToolSurface` — one instance per browser window,
/// pinning `tabManager` to that window's tab set so each AI session acts on
/// the window its chat lives in. `tabManager` is optional because a
/// window's TabManager can go away (window closed) while a floating AI
/// panel still holds the session.
@MainActor
protocol BrowserToolSurface: AnyObject {
    var tabManager: TabManager? { get }
    var bookmarkStore: BookmarkStore { get }
    var historyStore: HistoryStore { get }
    var contentBlocker: ContentBlockerStore { get }
    var readingListStore: ReadingListStore { get }
    var downloadStore: DownloadStore { get }
    var siteSettingsStore: SiteSettingsStore { get }
    var settings: Settings { get }
    var videoAdBlocker: VideoAdBlocker { get }
    var pluginStore: PluginStore { get }
    var elementBlockStore: ElementBlockStore { get }
    var tabGroupStore: TabGroupStore { get }
    var quickDialStore: QuickDialStore { get }
    var agentPreference: AgentPreferenceStore { get }
    var passwordStore: PasswordStore { get }
    /// 已保存的历史对话（`searchConversations` / `readConversation` 工具的数据源）。
    var conversationStore: ConversationStore { get }
}
