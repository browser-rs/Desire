import Combine
import SwiftUI

@MainActor
class AppState: ObservableObject {
    let settings: Settings
    let contentBlocker: ContentBlocker
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    let passwordStore: PasswordStore
    let formAutofillStore: FormAutofillStore
    let downloadStore: DownloadStore
    let permissionStore: PermissionStore
    let siteSettingsStore: SiteSettingsStore
    let quickDialStore: QuickDialStore
    let readingListStore: ReadingListStore
    let pluginStore: PluginStore
    let tabGroupStore: TabGroupStore
    let elementBlockStore: ElementBlockStore
    let videoAdBlocker: VideoAdBlocker
    let aiSession: AISessionStore
    let conversationStore: ConversationStore
    let privacyModeStore: PrivacyModeStore
    let devToolsStore: DevToolsStore
    let searchHistoryStore: SearchHistoryStore

    init() {
        settings = Settings()
        contentBlocker = ContentBlocker()
        bookmarkStore = BookmarkStore()
        historyStore = HistoryStore()
        passwordStore = PasswordStore()
        formAutofillStore = FormAutofillStore()
        downloadStore = DownloadStore()
        permissionStore = PermissionStore()
        siteSettingsStore = SiteSettingsStore()
        quickDialStore = QuickDialStore()
        readingListStore = ReadingListStore()
        pluginStore = PluginStore()
        tabGroupStore = TabGroupStore()
        elementBlockStore = ElementBlockStore()
        videoAdBlocker = VideoAdBlocker()
        aiSession = AISessionStore()
        conversationStore = ConversationStore()
        privacyModeStore = PrivacyModeStore()
        devToolsStore = DevToolsStore()
        searchHistoryStore = SearchHistoryStore()
        aiSession.conversationStore = conversationStore
    }
}
