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
    /// Agent 会话（第五源：对话标题/首条消息搜索；回车直达 loadConversation）。
    var agentSession: AgentSessionStore? = nil
    let onClose: () -> Void
    /// 点击 Agent 会话结果时的宿主回调（打开 Agent 面板——面板归属 ContentView 状态）。
    var onOpenAgentPanel: (() -> Void)? = nil

    @State private var query = ""
    @State private var result = SearchEverywhere.Result()
    @State private var searchTask: Task<Void, Never>?
    /// 键盘导航：扁平化的可选中行（分组展平，与渲染顺序一致）。
    @State private var selectedIndex: Int? = nil
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
                // Agent 会话（第五源）：标题 + 消息正文（v0.8.6 补内容搜索的
                // 命中片段——此前正文命中行会被第二阶段 title/url 匹配滤掉）。
                if let agentSession {
                    for c in agentSession.conversationStore.conversations {
                        let titleHit = c.title.lowercased().contains(q.lowercased())
                        let matchedMessage = c.messages.first {
                            ($0.content ?? "").lowercased().contains(q.lowercased())
                        }
                        if titleHit || matchedMessage != nil {
                            var snippet: String?
                            var hitMessageID: UUID?
                            if let message = matchedMessage, let text = message.content {
                                hitMessageID = message.id
                                let lowered = text.lowercased()
                                if let range = lowered.range(of: q.lowercased()) {
                                    let lower = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
                                    let upper = text.index(range.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
                                    snippet = (lower > text.startIndex ? "…" : "")
                                        + text[lower..<upper].replacingOccurrences(of: "\n", with: " ")
                                }
                            }
                            items.append(.init(
                                source: .agentConversation, id: c.id.uuidString,
                                title: c.title, url: "desire://conversation/\(c.id.uuidString)",
                                snippet: snippet,
                                // v0.8.6：带上命中消息 id，打开后跳转并高亮该轮。
                                targetMessageID: hitMessageID,
                                matchedQuery: q))
                        }
                    }
                }
                let r = SearchEverywhere.search(q, items: items)
                await MainActor.run {
                    result = r
                    selectedIndex = nil   // 新结果集重置键盘选择
                }
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
                .onKeyPress(.downArrow, phases: .down) { _ in
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow, phases: .down) { _ in
                    moveSelection(-1)
                    return .handled
                }
                .onSubmit {
                    // 回车 = 打开键盘选中行（无选中 = 第一行）。
                    let rows = flatRows
                    guard !rows.isEmpty else { return }
                    let idx = min(selectedIndex ?? 0, rows.count - 1)
                    activate(rows[max(0, idx)])
                }
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

    /// 键盘导航用的**扁平行序列**（与渲染顺序一致：分组顺序展平）。
    private var flatRows: [SearchEverywhere.Hit] {
        if result.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
            return defaultTabItems.map {
                .init(source: .tab, id: $0.id, title: $0.title, url: $0.url, matchedIn: "title")
            }
        }
        return result.tabs + result.history + result.bookmarks + result.readingList
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
                    if !result.agentConversations.isEmpty {
                        group("Agent Conversations", result.agentConversations,
                              systemImage: "bubble.left.and.text.bubble.right")
                    }
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
        let rows = flatRows
        let flatIndex = rows.firstIndex(where: { $0.source == hit.source && $0.id == hit.id })
        let isSelected = flatIndex != nil && selectedIndex == flatIndex
        return Button {
            activate(hit)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(attributedTitle(hit.title.isEmpty ? hit.url : hit.title))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(hit.snippet ?? hit.url)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hit.source == .tab {
                    Text("Tab")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(appAccent)
                } else if hit.source == .agentConversation {
                    Text("Chat")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(appAccent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? appAccent.opacity(0.14)
                          : Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 高亮匹配片段（设计评审验收"高亮匹配片段"）：At |tributedString 局部
    /// 强调（前景强调色+semibold），大小写不敏感首个命中。
    private func attributedTitle(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty,
              let range = attr.range(of: q, options: .caseInsensitive) else {
            return attr
        }
        attr[range].foregroundColor = appAccent
        attr[range].font = .system(size: 12.5, weight: .bold)
        return attr
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

    private func moveSelection(_ delta: Int) {
        let rows = flatRows
        guard !rows.isEmpty else { return }
        let current = selectedIndex ?? -1
        selectedIndex = min(max(current + delta, 0), rows.count - 1)
    }

    private func activate(_ hit: SearchEverywhere.Hit) {
        switch hit.source {
        case .tab:
            if let id = UUID(uuidString: hit.id),
               let idx = tabManager.tabs.firstIndex(where: { $0.id == id }) {
                tabManager.selectTab(at: idx)
            }
        case .agentConversation:
            // Agent 会话：载入会话并打开 Agent 面板（宿主回调）。
            // content 命中时带消息 id——面板载入后跳转并高亮那一轮（v0.8.6）。
            if let id = UUID(uuidString: hit.id), let agentSession {
                agentSession.loadConversation(id)
                if let messageID = hit.targetMessageID {
                    NotificationCenter.default.post(
                        name: .agentJumpToMessage,
                        object: nil,
                        userInfo: [
                            "conversationID": id.uuidString,
                            "messageID": messageID.uuidString,
                            "query": hit.matchedQuery ?? "",
                        ])
                }
                onOpenAgentPanel?()
            }
        case .history, .bookmark, .readingList:
            tabManager.addTab(url: hit.url, makeActive: true)
        }
        onClose()
    }
}
