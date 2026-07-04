import SwiftUI

enum SidebarTab: String, CaseIterable {
    case bookmarks = "书签"
    case history = "历史"
    case readingList = "阅读列表"

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
                    Button("打开") { if let url = bookmark.url { onNavigate(url) } }
                    Button("删除", role: .destructive) { bookmarkStore.remove(bookmark) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if bookmarkStore.allBookmarks.isEmpty {
                emptyState("无书签")
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
                    Button("打开") { onNavigate(entry.url) }
                    Button("删除", role: .destructive) { historyStore.removeEntry(id: entry.id) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if historyStore.entries.isEmpty {
                emptyState("无历史记录")
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
                    Button(item.isRead ? "标记未读" : "标记已读") { readingListStore.toggleRead(item.id) }
                    Button("删除", role: .destructive) { readingListStore.remove(item.id) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if readingListStore.items.isEmpty {
                emptyState("阅读列表为空")
            }
        }
    }
}
