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

    init() {
        bookmarkStore = BookmarkStore()
        historyStore = HistoryStore()
        downloadStore = DownloadStore()
    }
}

/// AI stores. (Step 2 will hoist `AIPreferenceStore` out of `AISessionStore`
/// to be owned here directly; for now it stays nested inside `aiSession` and
/// is exposed via the `preference` accessor so consumers already migrate to
/// `ai.preference`.)
@MainActor
class AIState: ObservableObject {
    lazy var aiSession = AISessionStore()
    lazy var conversationStore = ConversationStore()

    /// Convenience: the AI preference store. Currently nested inside
    /// `aiSession`; will become a top-level `let` in step 2.
    var preference: AIPreferenceStore { aiSession.preference }
}

/// Privacy / security stores: content blocking, passwords, autofill,
/// permissions, element blocking, video ad blocking, private-browsing mode.
@MainActor
class PrivacyState: ObservableObject {
    let contentBlocker: ContentBlocker

    lazy var passwordStore = PasswordStore()
    lazy var formAutofillStore = FormAutofillStore()
    lazy var permissionStore = PermissionStore()
    lazy var elementBlockStore = ElementBlockStore()
    lazy var videoAdBlocker = VideoAdBlocker()
    lazy var privacyModeStore = PrivacyModeStore()

    init() {
        contentBlocker = ContentBlocker()
    }
}

/// System / settings stores: app settings, per-site settings, dev tools,
/// plugins (userscripts), Safari extensions, performance manager.
@MainActor
class SystemState: ObservableObject {
    let settings: Settings

    lazy var siteSettingsStore = SiteSettingsStore()
    lazy var devToolsStore = DevToolsStore()
    lazy var pluginStore = PluginStore()
    lazy var safariExtensionManager = SafariExtensionManager()
    lazy var performanceManager = PerformanceManager()

    init() {
        settings = Settings()
    }
}
