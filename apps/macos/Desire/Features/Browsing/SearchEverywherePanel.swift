import SwiftUI
import WebKit

/// 集中搜索面板（0.7.14）：⌘⇧F 打开，跨打开标签/历史/书签/阅读列表四源同搜。
/// 分组展示、回车直达（打开标签 → switchTab，其余 → 新后台标签）。
/// 查询逻辑在 SearchEverywhere（纯函数，四源并发由调用方裁剪为 Item 快照）。
struct SearchEverywherePanel: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var tabManager: TabManager
    let historyStore: HistoryStore
    let bookmarkStore: BookmarkStore
    let readingListStore: ReadingListStore
    let settings: Settings
    let contentBlocker: ContentBlockerStore
    let videoAdBlocker: VideoAdBlocker
    let onClose: () -> Void

    @State private var query = ""
    @State private var result = SearchEverywhere.Result()
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    /// 当前选中标签 id（回车直达 switchTab 用）。
    private var openTabItems: [SearchEverywhere.Item] {
        tabManager.tabs.enumerated().map { idx, tab in
            .init(source: .tab, id: tab.id.uuidString,
                  title: tab.displayTitle,
                  url: tab.browser.webView.url?.absoluteString ?? tab.urlString)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            results
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 440)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            let q = newValue
            guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                result = SearchEverywhere.Result()
                return
            }
            searchTask = Task { [historyStore, bookmarkStore, readingListStore] in
                // 去抖 120ms（即输即滤但不逐键全扫）。
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                var items = openTabItems
                items += historyStore.entries.map {
                    SearchEverywhere.Item(source: .history, id: $0.id.uuidString,
                                          title: $0.title, url: $0.url)
                }
                items += flattenBookmarks(bookmarkStore.bookmarks)
                items += readingListStore.items.map {
                    SearchEverywhere.Item(source: .readingList, id: $0.id.uuidString,
                                          title: $0.title, url: $0.url)
                }
                let r = SearchEverywhere.search(q, items: items)
                await MainActor.run { result = r }
            }
        }
    }

    private func flattenBookmarks(_ tree: [Bookmark]) -> [SearchEverywhere.Item] {
        var out: [SearchEverywhere.Item] = []
        func walk(_ nodes: [Bookmark]) {
            for b in nodes {
                if b.isLeaf, let url = b.url {
                    out.append(.init(source: .bookmark, id: b.id.uuidString,
                                     title: b.title, url: url))
                }
                walk(b.children)
            }
        }
        walk(tree)
        return out
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Search Everywhere")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search tabs, history, bookmarks, reading list…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .onSubmit { openFirst() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 空查询默认结果 = 打开标签（验收口径 0.7.14：面板打开即有用，不用先想关键词）。
    private var defaultTabItems: [SearchEverywhere.Item] {
        tabManager.tabs.enumerated().map { idx, tab in
            .init(source: .tab, id: tab.id.uuidString,
                  title: tab.displayTitle,
                  url: tab.browser.webView.url?.absoluteString ?? tab.urlString)
        }
    }

    @ViewBuilder
    private var results: some View {
        if result.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty, !defaultTabItems.isEmpty {
                // 空查询默认态：直接列出打开标签（与"Open Tabs"分组同款行）。
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        group("Open Tabs", defaultTabItems.map {
                            SearchEverywhere.Hit(source: .tab, id: $0.id,
                                                 title: $0.title, url: $0.url,
                                                 matchedIn: "title")
                        }, systemImage: "tab")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "questionmark.square")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !result.tabs.isEmpty { group("Open Tabs", result.tabs, systemImage: "tab") }
                    if !result.history.isEmpty { group("History", result.history, systemImage: "clock") }
                    if !result.bookmarks.isEmpty { group("Bookmarks", result.bookmarks, systemImage: "book") }
                    if !result.readingList.isEmpty { group("Reading List", result.readingList, systemImage: "eyeglasses") }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private func group(_ title: String, _ hits: [SearchEverywhere.Hit], systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
            ForEach(hits) { hit in
                hitRow(hit)
            }
        }
    }

    private func hitRow(_ hit: SearchEverywhere.Hit) -> some View {
        Button {
            activate(hit)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.title.isEmpty ? hit.url : hit.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(hit.url)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hit.source == .tab {
                    Text("Tab")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(appAccent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func openFirst() {
        for hits in [result.tabs, result.history, result.bookmarks, result.readingList] {
            if let first = hits.first {
                activate(first)
                return
            }
        }
    }

    private func activate(_ hit: SearchEverywhere.Hit) {
        switch hit.source {
        case .tab:
            if let id = UUID(uuidString: hit.id),
               let idx = tabManager.tabs.firstIndex(where: { $0.id == id }) {
                tabManager.selectTab(at: idx)
            }
        case .history, .bookmark, .readingList:
            tabManager.addTab(url: hit.url, makeActive: true)
        }
        onClose()
    }
}
