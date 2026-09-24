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
    /// Process-wide instance (weak, same pattern as `DownloadStore.live`) —
    /// the automation bridge reaches app-shell UI state through it.
    static private(set) weak var live: AppState?

    let browsing: BrowsingState
    let ai: AgentState
    let privacy: PrivacyState
    let system: SystemState
    /// 云同步（书签/快拨/阅读列表/快捷键）。挂在组合根而非域容器：
    /// 一个域横跨 BrowsingState（书签等）与 SystemState（快捷键）。
    let syncStore: SyncStore

    /// Whether the downloads popover is open. Lives here (not in Toolbar
    /// local state) so the automation bridge can open the panel to
    /// screenshot SwiftUI chrome that the webview-only /screenshot misses.
    @Published var showDownloadsPanel = false

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
        syncStore = SyncStore(
            bookmarkStore: browsing.bookmarkStore,
            quickDialStore: browsing.quickDialStore,
            readingListStore: browsing.readingListStore,
            shortcutStore: system.keyboardShortcutStore,
            settings: system.settings
        )
        Self.live = self
        // 恢复上次活跃人物的数据作用域（cookie 隔离由各窗口在
        // 创建标签时经 profileDataStore 各自恢复）。
        let saved = UserDefaults.standard.string(forKey: "desire.activeProfile")
            .flatMap(UUID.init(uuidString:))
        if saved != nil, ProfileStore.shared.profile(for: saved) != nil {
            ProfileStore.shared.activeProfileID = saved
            browsing.bookmarkStore.applyScope(profileID: saved)
            browsing.historyStore.applyScope(profileID: saved)
            browsing.quickDialStore.applyScope(profileID: saved)
        }
        // 云同步：已登录才生效（内部自延迟 + 定时器，不占启动路径）。
        syncStore.startAutoSync()
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

    /// Profiles 闭环（0.3.5）：切换活跃人物——cookie 隔离走各窗口的
    /// profileDataStore（窗口自己管），数据作用域（书签/历史/快拨）
    /// 在这里统一切桶。当前人物持久化，重启沿用。
    func applyProfile(_ id: UUID?) {
        ProfileStore.shared.activeProfileID = id
        UserDefaults.standard.set(id?.uuidString, forKey: "desire.activeProfile")
        bookmarkStore.applyScope(profileID: id)
        historyStore.applyScope(profileID: id)
        quickDialStore.applyScope(profileID: id)
    }
}
