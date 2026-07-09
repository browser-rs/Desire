import Combine
import SwiftUI

/// Global app state container. Uses lazy initialization for most stores
/// to improve startup performance - only essential stores are created
/// immediately; others are deferred until first access.
@MainActor
class AppState: ObservableObject {
    // Essential stores - created immediately for UI that needs them on launch
    let settings: Settings
    let contentBlocker: ContentBlocker
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    let downloadStore: DownloadStore

    // Lazy stores - created on first access to reduce startup time
    lazy var passwordStore: PasswordStore = PasswordStore()
    lazy var formAutofillStore: FormAutofillStore = FormAutofillStore()
    lazy var permissionStore: PermissionStore = PermissionStore()
    lazy var siteSettingsStore: SiteSettingsStore = SiteSettingsStore()
    lazy var quickDialStore: QuickDialStore = QuickDialStore()
    lazy var readingListStore: ReadingListStore = ReadingListStore()
    lazy var pluginStore: PluginStore = PluginStore()
    lazy var safariExtensionManager: SafariExtensionManager = SafariExtensionManager()
    lazy var tabGroupStore: TabGroupStore = TabGroupStore()
    lazy var elementBlockStore: ElementBlockStore = ElementBlockStore()
    lazy var videoAdBlocker: VideoAdBlocker = VideoAdBlocker()
    lazy var aiSession: AISessionStore = AISessionStore()
    lazy var conversationStore: ConversationStore = ConversationStore()
    lazy var privacyModeStore: PrivacyModeStore = PrivacyModeStore()
    lazy var devToolsStore: DevToolsStore = DevToolsStore()
    lazy var searchHistoryStore: SearchHistoryStore = SearchHistoryStore()
    lazy var performanceManager: PerformanceManager = PerformanceManager()

    // Flag to track if AI has been initialized
    private var aiInitialized = false

    init() {
        // Only create essential stores synchronously
        settings = Settings()
        contentBlocker = ContentBlocker()
        bookmarkStore = BookmarkStore()
        historyStore = HistoryStore()
        downloadStore = DownloadStore()
    }

    /// Initialize AI-related stores on demand (e.g., when user opens AI panel)
    func initializeAIIfNeeded() {
        if !aiInitialized {
            aiInitialized = true
            aiSession.conversationStore = conversationStore
        }
    }
}
