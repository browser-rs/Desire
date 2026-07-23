import Combine
import SwiftUI

/// Global app state container — now a composition root over four domain
/// containers (`BrowsingState`, `AIState`, `PrivacyState`, `SystemState`).
///
/// Previously this held all ~22 stores flat (a god object / manual service
/// locator). The stores now live on the scoped containers; the accessors
/// below forward to them so existing call sites (`appState.bookmarkStore`,
/// `appState.aiSession`, ...) keep working unchanged.
///
/// `hasRestoredSession` is the only non-store state here — a non-persistent
/// flag set by the first window's `onAppear` to gate session restore.
@MainActor
class AppState: ObservableObject {
    let browsing: BrowsingState
    let ai: AIState
    let privacy: PrivacyState
    let system: SystemState

    /// Tracks whether the launch session has been restored. Set to true by
    /// the first window's `onAppear`; subsequent user-opened windows skip
    /// restore and open a fresh tab instead of cloning the saved session.
    /// Non-persistent — resets each app launch.
    var hasRestoredSession = false

    init() {
        browsing = BrowsingState()
        ai = AIState()
        privacy = PrivacyState()
        system = SystemState()
    }

    // MARK: - Forwarding accessors
    // Preserve the flat API existing consumers expect; each delegates to the
    // owning scoped container.

    // Browsing
    var bookmarkStore: BookmarkStore { browsing.bookmarkStore }
    var historyStore: HistoryStore { browsing.historyStore }
    var downloadStore: DownloadStore { browsing.downloadStore }
    var quickDialStore: QuickDialStore { browsing.quickDialStore }
    var readingListStore: ReadingListStore { browsing.readingListStore }
    var tabGroupStore: TabGroupStore { browsing.tabGroupStore }
    var searchHistoryStore: SearchHistoryStore { browsing.searchHistoryStore }

    // AI
    var aiSession: AISessionStore { ai.aiSession }
    var conversationStore: ConversationStore { ai.conversationStore }
    var aiPreference: AIPreferenceStore { ai.preference }

    // Privacy
    var contentBlocker: ContentBlockerStore { privacy.contentBlocker }
    var passwordStore: PasswordStore { privacy.passwordStore }
    var formAutofillStore: FormAutofillStore { privacy.formAutofillStore }
    var permissionStore: PermissionStore { privacy.permissionStore }
    var elementBlockStore: ElementBlockStore { privacy.elementBlockStore }
    var videoAdBlocker: VideoAdBlocker { privacy.videoAdBlocker }
    var privacyModeStore: PrivacyModeStore { privacy.privacyModeStore }

    // System
    var settings: Settings { system.settings }
    var siteSettingsStore: SiteSettingsStore { system.siteSettingsStore }
    var devToolsStore: DevToolsStore { system.devToolsStore }
    var pluginStore: PluginStore { system.pluginStore }
    var safariExtensionManager: SafariExtensionStore { system.safariExtensionManager }
    var performanceManager: PerformanceStore { system.performanceManager }

    // MARK: - BrowserToolSurface runtime wiring

    /// The current window's TabManager. Tabs are per-window (each window owns
    /// its own TabManager), so AppState can't own one; each window's
    /// `ContentView` attaches its TabManager here so AI tools can address the
    /// active tab set. Weak to avoid retaining a per-window object globally.
    private weak var _tabManager: TabManager?

    /// Attaches the active window's TabManager so `BrowserToolSurface`
    /// consumers (the AI tool provider) can reach it. Called per window on
    /// `ContentView.onAppear`.
    func attach(tabManager: TabManager) {
        _tabManager = tabManager
    }
}

// MARK: - BrowserToolSurface

extension AppState: BrowserToolSurface {
    var tabManager: TabManager? { _tabManager }
}
