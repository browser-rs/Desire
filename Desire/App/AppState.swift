import Combine
import SwiftUI

/// Global app state container — now a composition root over four domain
/// containers (`BrowsingState`, `AgentState`, `PrivacyState`, `SystemState`).
///
/// Previously this held all ~22 stores flat (a god object / manual service
/// locator). The stores now live on the scoped containers; the accessors
/// below forward to them so existing call sites (`appState.bookmarkStore`,
/// ...) keep working unchanged.
///
/// `hasRestoredSession` is the only non-store state here — a non-persistent
/// flag set by the first window's `onAppear` to gate session restore.
///
/// Note: this type is intentionally NOT a `BrowserToolSurface`. Tool
/// surfaces are per-window (`WindowToolSurface`) so each AI session acts on
/// its own window's tabs; a shared surface here would target whichever
/// window was last key.
@MainActor
class AppState: ObservableObject {
    let browsing: BrowsingState
    let ai: AgentState
    let privacy: PrivacyState
    let system: SystemState

    /// Tracks whether the launch session has been restored. Set to true by
    /// the first window's `onAppear`; subsequent user-opened windows skip
    /// restore and open a fresh tab instead of cloning the saved session.
    /// Non-persistent — resets each app launch.
    var hasRestoredSession = false

    init() {
        browsing = BrowsingState()
        ai = AgentState()
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
    var conversationStore: ConversationStore { ai.conversationStore }
    var aiPreference: AgentPreferenceStore { ai.preference }

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

    // MARK: - Session persistence wiring

    /// Records the active window's TabManager as the session-persistence
    /// target. Called on window creation and again whenever the window
    /// becomes key (WindowChromeGuard.onBecomeKey). AI tools no longer ride
    /// this pointer — see `WindowToolSurface`.
    func attach(tabManager: TabManager) {
        TabSessionCoordinator.shared.setActive(tabManager)
    }
}
