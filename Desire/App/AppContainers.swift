import Combine
import Foundation

/// Scoped state containers composed by `AppState`.
///
/// `AppState` previously held all ~22 stores flat, making it a god object /
/// manual service locator that every feature reached into via
/// `appState.fooStore`. It is now decomposed into domain-grouped containers so
/// ownership is legible and each domain can be reasoned about (and eventually
/// tested) in isolation.
///
/// Each container preserves the original eager/lazy split: stores needed on
/// launch are `let` (constructed in `init`); the rest stay `lazy` so startup
/// cost is unchanged. No store has an init-time dependency on another, so the
/// containers are independent and can be constructed in any order.

/// Browsing-core stores: bookmarks, history, downloads, and the per-tab
/// supporting stores (quick dials, reading list, tab groups, search history).
@MainActor
class BrowsingState: ObservableObject {
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    let downloadStore: DownloadStore

    lazy var quickDialStore = QuickDialStore()
    lazy var readingListStore = ReadingListStore()
    lazy var tabGroupStore = TabGroupStore()
    lazy var searchHistoryStore = SearchHistoryStore()

    /// 云同步（首域 = 书签）。lazy：需要 bookmarkStore 先就位。
    lazy var syncStore = SyncStore(bookmarkStore: bookmarkStore)

    init() {
        bookmarkStore = BookmarkStore()
        historyStore = HistoryStore()
        downloadStore = DownloadStore()
    }
}

/// AI stores. `AgentPreferenceStore` is the single source of truth for AI
/// preferences (model, endpoint, API key, provider kind, ...); the
/// per-window `AgentSessionStore`s (one per browser window, created by each
/// `ContentView`) share this one instance so Settings edits reach every
/// live agent. `ConversationStore` is likewise shared so any window can
/// load a saved conversation.
@MainActor
class AgentState: ObservableObject {
    let preference: AgentPreferenceStore
    let conversationStore: ConversationStore

    init() {
        preference = AgentPreferenceStore()
        conversationStore = ConversationStore()
    }
}

/// Privacy / security stores: content blocking, passwords, autofill,
/// permissions, element blocking, video ad blocking, private-browsing mode.
@MainActor
class PrivacyState: ObservableObject {
    let contentBlocker: ContentBlockerStore

    lazy var passwordStore = PasswordStore()
    lazy var formAutofillStore = FormAutofillStore()
    lazy var permissionStore = PermissionStore()
    lazy var elementBlockStore = ElementBlockStore()
    lazy var videoAdBlocker = VideoAdBlocker()
    lazy var privacyModeStore = PrivacyModeStore.shared

    init() {
        contentBlocker = ContentBlockerStore()
    }
}

/// System / settings stores: app settings, per-site settings, dev tools,
/// plugins (userscripts), Safari extensions.
@MainActor
class SystemState: ObservableObject {
    let settings: Settings

    lazy var siteSettingsStore = SiteSettingsStore()
    lazy var devToolsStore: DevToolsStore = {
        let store = DevToolsStore()
        store.pluginStore = pluginStore
        return store
    }()
    lazy var pluginStore = PluginStore()
    lazy var safariExtensionManager = SafariExtensionStore()
    /// Single shared instance: menu commands, the window's hidden shortcut
    /// buttons, and the Settings editor must all observe the SAME object or
    /// customizations would not reach the menus (the settings editor used to
    /// own a private instance — customizations saved to disk and died there).
    lazy var keyboardShortcutStore = KeyboardShortcutStore()

    init() {
        settings = Settings()
    }
}
