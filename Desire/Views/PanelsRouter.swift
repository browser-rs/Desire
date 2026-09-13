import SwiftUI

/// Presents the app's modal panels: history, bookmarks, search history,
/// extensions, reading list, element blocker, and the plugins window
/// trigger. Extracted from `ContentView.body` (roadmap L1-1) — one modifier
/// instead of six inline sheet blocks.
///
/// Stores are plain `let` references (closures read them live at callback
/// time); panel visibility comes in as bindings owned by `ContentView`.
struct PanelsRouter: ViewModifier {
    let settings: Settings
    let historyStore: HistoryStore
    let bookmarkStore: BookmarkStore
    let searchHistoryStore: SearchHistoryStore
    let readingListStore: ReadingListStore
    let elementBlockStore: ElementBlockStore
    let pluginStore: PluginStore
    let extensionManager: SafariExtensionStore

    @Binding var showHistory: Bool
    @Binding var showBookmarks: Bool
    @Binding var showSearchHistory: Bool
    @Binding var showPlugins: Bool
    @Binding var showExtensions: Bool
    @Binding var showReadingList: Bool
    @Binding var showElementBlock: Bool

    /// Navigates the selected tab (panel selection callbacks).
    let onNavigate: (String) -> Void
    /// Kicks off the element picker for the selected tab.
    let onStartElementPicker: () -> Void
    let onDeleteBookmark: (Bookmark) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showHistory) {
                HistoryPanel(store: historyStore, onSelect: { url in
                    showHistory = false
                    onNavigate(url)
                }, onClose: { showHistory = false })
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarkPanel(store: bookmarkStore, onSelect: { url in
                    showBookmarks = false
                    onNavigate(url)
                }, onDelete: onDeleteBookmark, onClose: { showBookmarks = false })
            }
            .sheet(isPresented: $showSearchHistory) {
                SearchHistoryPanel(store: searchHistoryStore, onSelect: { query in
                    showSearchHistory = false
                    let url = settings.searchURLTemplate
                        + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
                    onNavigate(url)
                }, onClose: { showSearchHistory = false })
            }
            .onChange(of: showPlugins) { _, isShown in
                guard isShown else { return }
                showPlugins = false
                PluginsWindowController.shared.show(pluginStore: pluginStore)
            }
            .sheet(isPresented: $showExtensions) {
                SafariExtensionPanel(manager: extensionManager)
            }
            .sheet(isPresented: $showReadingList) {
                ReadingListPanel(store: readingListStore, onSelect: { url in
                    showReadingList = false
                    onNavigate(url)
                }, onClose: { showReadingList = false })
            }
            .sheet(isPresented: $showElementBlock) {
                ElementBlockPanel(store: elementBlockStore, onStartPicker: onStartElementPicker, onClose: { showElementBlock = false })
            }
    }
}
