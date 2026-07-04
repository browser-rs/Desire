import SwiftUI

enum SidebarTab: String, CaseIterable {
    case bookmarks
    case history
    case readingList

    var icon: String {
        switch self {
        case .bookmarks: "bookmark"
        case .history: "clock"
        case .readingList: "bookmark.slash"
        }
    }
}

struct SidebarView: View {
    @ObservedObject var bookmarkStore: BookmarkStore
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var readingListStore: ReadingListStore
    @State private var selectedTab: SidebarTab = .bookmarks
    let onNavigate: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Image(systemName: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            switch selectedTab {
            case .bookmarks:
                sidebarBookmarks
            case .history:
                sidebarHistory
            case .readingList:
                sidebarReadingList
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarBookmarks: some View {
        List {
            ForEach(bookmarkStore.allBookmarks) { bookmark in
                EntryRow(title: bookmark.title, subtitle: bookmark.url ?? "") {
                    if let url = bookmark.url { onNavigate(url) }
                }
                .contextMenu {
                    Button("Open") { if let url = bookmark.url { onNavigate(url) } }
                    Button("Delete", role: .destructive) { bookmarkStore.remove(bookmark) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if bookmarkStore.allBookmarks.isEmpty {
                EmptyState(message: String(localized: "No Bookmarks"))
            }
        }
    }

    private var sidebarHistory: some View {
        List {
            ForEach(historyStore.entries) { entry in
                EntryRow(title: entry.title, subtitle: entry.url) {
                    onNavigate(entry.url)
                }
                .contextMenu {
                    Button("Open") { onNavigate(entry.url) }
                    Button("Delete", role: .destructive) { historyStore.removeEntry(id: entry.id) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if historyStore.entries.isEmpty {
                EmptyState(message: String(localized: "No History"))
            }
        }
    }

    private var sidebarReadingList: some View {
        List {
            ForEach(readingListStore.items) { item in
                EntryRow(title: item.title, subtitle: item.url) {
                    onNavigate(item.url)
                }
                .contextMenu {
                    Button(item.isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read")) { readingListStore.toggleRead(item.id) }
                    Button("Delete", role: .destructive) { readingListStore.remove(item.id) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if readingListStore.items.isEmpty {
                EmptyState(message: String(localized: "Reading List is Empty"))
            }
        }
    }
}
