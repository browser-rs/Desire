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

    /// 检索档位（v0.8.22）：智能 = 字面优先 + 语义补位；字面 = 只字面；
    /// 语义 = 只语义（按相关度）。选择记住到下次打开。
    enum SearchMode: String, CaseIterable {
        case smart, literal, semantic

        var title: String {
            switch self {
            case .smart: return String(localized: "Smart")
            case .literal: return String(localized: "Literal")
            case .semantic: return String(localized: "Meaning")
            }
        }
    }

    @State private var query = ""
    @State private var mode: SearchMode =
        SearchMode(rawValue: UserDefaults.standard.string(forKey: "search.everywhere.mode") ?? "") ?? .smart
    @State private var result = SearchEverywhere.Result()
    @State private var searchTask: Task<Void, Never>?
    /// 键盘导航：扁平化的可选中行（分组展平，与渲染顺序一致）。
    @State private var selectedIndex: Int? = nil
    /// 预览跟随（v0.8.11）：当前选中行的命中（nil = 无）。
    @State private var previewHit: SearchEverywhere.Hit?
    @FocusState private var fieldFocused: Bool
    /// 划词 → 语义检索（v0.8.25）：一次性请求，展开时消费。
    @ObservedObject private var related = RelatedSearchCenter.shared

    /// 当前选中标签 id（回车直达 switchTab 用）。
    private var openTabItems: [SearchEverywhere.Item] {
        tabManager.tabs.enumerated().map { idx, tab in
            .init(source: .tab, id: tab.id.uuidString,
                  title: tab.displayTitle,
                  url: tab.browser.webView.url?.absoluteString ?? tab.urlString)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                searchField
                modePicker
                results
            }
            .frame(minWidth: 380, idealWidth: 420)
            // 预览面板（v0.8.11）：跟随键盘选择的命中渲染首屏；回车才真正跳转。
            previewPane
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 440)
        .onAppear {
            LocalFileContentIndex.shared.warmUp()
            fieldFocused = true
            applyRelatedRequest()
        }
        .onChange(of: related.requestToken) { _, _ in
            applyRelatedRequest()
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            let q = newValue
            guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                result = SearchEverywhere.Result()
                return
            }
            rerunSearch(q)
        }
    }

    /// 消费"划词找相关内容"的请求：切语义档并填入查询（同 query 时手动重跑，
    /// 因为 `onChange(of: query)` 不会为相同值触发）。
    private func applyRelatedRequest() {
        guard let request = related.consume() else { return }
        if request.semantic, mode != .semantic { mode = .semantic }
        if query == request.text {
            rerunSearch(request.text)
        } else {
            query = request.text
        }
        fieldFocused = true
    }

    /// 跑一次检索（字面 + 按档位补语义）。查询变化与档位切换都走这里。
    private func rerunSearch(_ q: String) {
        searchTask?.cancel()
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
                            if let range = text.range(of: q, options: .caseInsensitive) {
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
                            targetMessageID: hitMessageID,
                            matchedQuery: q))
                    }
                }
            }
            items += LocalFileContentIndex.shared.matchingItems(query: q)
            for excerpt in ExcerptStore.shared.excerpts where excerpt.matches(q) {
                items.append(.init(
                    source: .excerpt, id: excerpt.id.uuidString,
                    title: excerpt.title, url: excerpt.source,
                    snippet: String(excerpt.content.prefix(120))))
            }
            let r = SearchEverywhere.search(q, items: items)
            let currentMode = mode
            var semantic: [SearchEverywhere.Hit] = []
            if currentMode != .literal {
                semantic = await Self.semanticHits(
                    query: q,
                    excluding: Set(items.compactMap { item -> String? in
                        let trimmed = item.url.lowercased()
                        return trimmed.isEmpty ? nil : trimmed
                    }),
                    limit: currentMode == .semantic ? 24 : 8)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                var merged = r
                merged.semantic = semantic
                result = merged
                selectedIndex = nil
            }
        }
    }

    /// 语义命中 → 面板行（排除字面已命中的 URL）。会话命中保留
    /// "conversation:<conv>:<msg>" 形态的 id，`activate` 据此跳转高亮。
    private static func semanticHits(query: String,
                                     excluding urls: Set<String>,
                                     limit: Int) async -> [SearchEverywhere.Hit] {
        let raw = await SemanticIndexStore.shared.searchAsync(query: query, limit: limit + 6)
        var out: [SearchEverywhere.Hit] = []
        for hit in raw {
            if out.count >= limit { break }
            let key = hit.subtitle.lowercased()
            if !key.isEmpty, urls.contains(key) { continue }
            let source: SearchEverywhere.Source
            switch hit.source {
            case .history: source = .history
            case .bookmark: source = .bookmark
            case .excerpt: source = .excerpt
            case .highlight: source = .highlight
            case .conversation: source = .agentConversation
            }
            out.append(SearchEverywhere.Hit(
                source: source,
                id: hit.id,
                title: hit.title,
                url: hit.source == .conversation ? "" : hit.subtitle,
                matchedIn: "semantic",
                snippet: hit.snippet,
                matchedQuery: query))
        }
        return out
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

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(SearchMode.allCases, id: \.self) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: mode) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: "search.everywhere.mode")
            // 档位变了先作废在飞请求，避免旧档结果覆盖新档。
            searchTask?.cancel()
            let q = query
            guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            rerunSearch(q)
        }
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
            + result.localFiles + result.excerpts + result.agentConversations
            + result.semantic
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
                    if !result.localFiles.isEmpty { group("Local Files", result.localFiles, systemImage: "doc") }
                    if !result.excerpts.isEmpty { group("Excerpts", result.excerpts, systemImage: "text.quote") }
                    if !result.agentConversations.isEmpty {
                        group("Agent Conversations", result.agentConversations,
                              systemImage: "bubble.left.and.text.bubble.right")
                    }
                    if !result.semantic.isEmpty {
                        group("Related by Meaning", result.semantic, systemImage: "sparkles")
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
                } else if hit.source == .localFile {
                    Text("File")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(appAccent)
                } else if hit.source == .excerpt {
                    Text("Clip")
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
        for hits in [result.tabs, result.history, result.bookmarks, result.readingList,
                     result.localFiles, result.excerpts, result.agentConversations, result.semantic] {
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

    // MARK: - 预览面板（v0.8.11）

    /// 当前预览目标：键盘选择行 → previewHit；都没选 → 第一行。
    private var activePreview: SearchEverywhere.Hit? {
        let rows = flatRows
        if let idx = selectedIndex, rows.indices.contains(idx) { return rows[idx] }
        return rows.first
    }

    @ViewBuilder
    private var previewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let hit = activePreview {
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: hit.source))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appAccent)
                        Text(Self.sourceLabel(hit.source))
                            .font(.system(size: 10.5, weight: .semibold))
                        Spacer()
                    }
                    Text(hit.title.isEmpty ? hit.url : hit.title)
                        .font(.system(size: 13, weight: .semibold))
                        .textSelection(.enabled)
                    Text(hit.url)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Divider()
                    // content 命中（Agent 会话正文）→ 命中片段；其余源 → 路径摘要。
                    if let snippet = hit.snippet {
                        Text(snippet)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    } else if hit.source == .agentConversation, let session = agentSession,
                              let id = UUID(uuidString: hit.id),
                              let conv = session.conversationStore.conversation(for: id) {
                        let recent = conv.messages.suffix(6).compactMap { message -> String? in
                            guard let text = message.content, !text.isEmpty else { return nil }
                            let role = message.role == .user ? "›" : "—"
                            return role + " " + String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
                        }
                        if recent.isEmpty {
                            Text(String(localized: "(no text content)"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(Array(recent.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11))
                                    .lineLimit(2)
                            }
                        }
                    } else {
                        Text(String(localized: "Enter opens it; the preview shows metadata only for this source."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(String(localized: "Preview"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func sourceLabel(_ source: SearchEverywhere.Source) -> String {
        switch source {
        case .tab: String(localized: "Open Tab")
        case .history: String(localized: "History")
        case .bookmark: String(localized: "Bookmark")
        case .readingList: String(localized: "Reading List")
        case .agentConversation: String(localized: "Agent Conversation")
        case .localFile: String(localized: "Local File")
        case .excerpt: String(localized: "Excerpt")
        case .highlight: String(localized: "Reading Highlight")
        }
    }

    private func icon(for source: SearchEverywhere.Source) -> String {
        switch source {
        case .tab: "tab"
        case .history: "clock"
        case .bookmark: "book"
        case .readingList: "eyeglasses"
        case .agentConversation: "bubble.left.and.text.bubble.right"
        case .localFile: "doc"
        case .excerpt: "text.quote"
        case .highlight: "highlighter"
        }
    }

    private func activate(_ hit: SearchEverywhere.Hit) {
        switch hit.source {
        case .tab:
            if let id = UUID(uuidString: hit.id),
               let idx = tabManager.tabs.firstIndex(where: { $0.id == id }) {
                tabManager.selectTab(at: idx)
            }
        case .agentConversation:
            // 语义命中的会话条目 id = "conversation:<conv>:<msg>"（v0.8.22）。
            if hit.matchedIn == "semantic" {
                let parts = hit.id.split(separator: ":")
                if parts.count == 3,
                   let conversationID = UUID(uuidString: String(parts[1])),
                   let messageID = UUID(uuidString: String(parts[2])),
                   let agentSession {
                    agentSession.loadConversation(conversationID)
                    NotificationCenter.default.post(
                        name: .agentJumpToMessage,
                        object: nil,
                        userInfo: [
                            "conversationID": conversationID.uuidString,
                            "messageID": messageID.uuidString,
                            "query": hit.matchedQuery ?? "",
                        ])
                    onOpenAgentPanel?()
                }
                onClose()
                return
            }
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
        case .history, .bookmark, .readingList, .localFile, .highlight:
            // 本地文件走 file:// 导航 → 查看器路由（PDF/表格/图片/文档直开）。
            tabManager.addTab(url: hit.url, makeActive: true)
        case .excerpt:
            // 摘录来源：与应用内摘录面板同口径——http 开本浏览器标签，
            // 文件路径走查看器路由（含 #page 深链）。
            tabManager.addTab(url: hit.url, makeActive: true)
        }
        onClose()
    }
}
