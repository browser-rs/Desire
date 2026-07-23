import Foundation

/// The slice of app state that AI browser tools operate over.
///
/// Replaces the 13 individually-injected `weak var` stores on
/// `BrowserToolProvider` (and the matching 13-parameter `configureStores`)
/// with a single protocol boundary. `AppState` conforms; the agent's tool
/// provider holds one `weak var surface` and resolves each tool's target via
/// the protocol. Adding a new store that tools can address is now a one-line
/// protocol addition + conformance, not a 3-file edit.
///
/// `tabManager` is optional because tabs are per-window; `AppState` cannot
/// own one, so it's attached at runtime by each window's `ContentView`. All
/// other surfaces are non-optional (always present once AppState exists).
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
}
