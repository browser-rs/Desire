import Foundation

/// Per-window `BrowserToolSurface`: forwards every shared store to the
/// global `AppState` but pins `tabManager` to the window that owns the
/// AI session.
///
/// The old wiring attached the active window's TabManager to the SHARED
/// `AppState` surface, so tools executed against whichever browser window
/// was last key — a chat in the floating AI panel (whose NSPanel takes the
/// key) or in a background window's sidebar would navigate/read some other
/// window's tab. Each `ContentView` now configures its session with a
/// surface bound to its own TabManager, so the agent always acts on the
/// window the chat lives in.
@MainActor
final class WindowToolSurface: BrowserToolSurface {
    /// The owning window's tab set, fixed at construction (weak: the
    /// window's ContentView retains the TabManager).
    weak var tabManager: TabManager?

    private let app: AppState

    init(app: AppState, tabManager: TabManager) {
        self.app = app
        self.tabManager = tabManager
    }

    // Shared stores — same instances the rest of the app uses.
    var bookmarkStore: BookmarkStore { app.bookmarkStore }
    var historyStore: HistoryStore { app.historyStore }
    var contentBlocker: ContentBlockerStore { app.contentBlocker }
    var readingListStore: ReadingListStore { app.readingListStore }
    var downloadStore: DownloadStore { app.downloadStore }
    var siteSettingsStore: SiteSettingsStore { app.siteSettingsStore }
    var settings: Settings { app.settings }
    var videoAdBlocker: VideoAdBlocker { app.videoAdBlocker }
    var pluginStore: PluginStore { app.pluginStore }
    var elementBlockStore: ElementBlockStore { app.elementBlockStore }
    var tabGroupStore: TabGroupStore { app.tabGroupStore }
    var quickDialStore: QuickDialStore { app.quickDialStore }
    var agentPreference: AgentPreferenceStore { app.aiPreference }
    var passwordStore: PasswordStore { app.passwordStore }
}
