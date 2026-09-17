import SwiftUI

enum SidebarTab: String, CaseIterable {
    case bookmarks
    case history
    case readingList

    var icon: String {
        switch self {
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        case .readingList: "bookmark.slash"
        }
    }

    var help: LocalizedStringKey {
        switch self {
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .readingList: "Reading List"
        }
    }
}

struct SidebarView: View {
    @ObservedObject var bookmarkStore: BookmarkStore
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var readingListStore: ReadingListStore
    @State private var selectedTab: SidebarTab = .bookmarks
    @State private var hoveredTab: SidebarTab?
    let onNavigate: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabBar

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
        // Width is owned by the hosting HSplitView (min 180 / ideal 220 /
        // max 400) — an internal fixed frame would fight the splitter.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Custom capsule-style tab bar — replaces the default segmented Picker
    /// with a calmer, flatter row of icon buttons that match the rest of the
    /// app's chrome (RoundedRectangle(cornerRadius: 6), accent-color active state).
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func tabButton(_ tab: SidebarTab) -> some View {
        let isActive = selectedTab == tab
        let isHovered = hoveredTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isActive
                                ? Color.accentColor.opacity(0.15)
                                : (isHovered ? Color(nsColor: .systemFill) : Color.clear)
                        )
                )
                .foregroundStyle(isActive ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
        }
        .help(tab.help)
        .accessibilityLabel(tab.help)
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
