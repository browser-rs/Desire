import AppKit
import SwiftUI

/// Sidebar-style list of saved conversations. Supports search and groups
/// entries by recency (Today / Yesterday / This Week / Older).
struct AgentHistoryListView: View {
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var sessionStore: AgentSessionStore
    var onSelect: (UUID) -> Void
    var onBack: () -> Void

    @State private var searchText: String = ""
    /// 列表多选（`List(selection:)`，⌘/⇧ 点击原生支持）。选中 1 条 = 打开该会话，
    /// 选中多条 = 进入批量模式（顶部出现操作条）。
    @State private var selection = Set<UUID>()
    /// 正在行内重命名的会话（由滑动/右键触发）。
    @State private var renamingID: UUID?
    /// 防抖后的搜索词:过滤对每条会话每条消息做全文扫描,直接跟键
    /// 会随每次按键全量重扫。结果缓存盒按 (词, 会话数, 更新时间) 失效。
    @State private var debouncedQuery: String = ""
    @State private var searchDebounce: Task<Void, Never>?
    private final class FilterCacheBox {
        var key: String = ""
        var stamp: String = ""
        var out: [Conversation] = []
    }
    @State private var filterCache = FilterCacheBox()

    var body: some View {
        VStack(spacing: 0) {
            header
            if selection.count > 1 {
                batchBar
            } else {
                searchField
            }
            content
        }
        .onChange(of: selection) { _, newValue in
            // 原生语义：单选 = 打开；多选 = 批量模式（不打开）。
            if newValue.count == 1, let id = newValue.first, id != sessionStore.conversationId {
                onSelect(id)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("History")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(conversationStore.conversations.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search conversations", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: searchText) { _, query in
                    // 300ms 防抖:打字期间不做全量正文扫描。
                    searchDebounce?.cancel()
                    searchDebounce = Task {
                        try? await Task.sleep(for: .seconds(0.3))
                        guard !Task.isCancelled else { return }
                        debouncedQuery = query
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Batch bar

    /// 多选时顶部的操作条：批量删除 / 取消选择。删除前统一确认一次。
    private var batchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(appAccent)
            Text("\(selection.count) selected")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button {
                // 全选当前列表里的（含分组里的全部）
                selection = Set(filteredGrouped.flatMap { $0.items.map(\.id) })
            } label: {
                Text("Select All").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                confirmDelete(ids: selection)
            } label: {
                Text("Delete")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            Button {
                selection.removeAll()
            } label: {
                Text("Deselect").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if conversationStore.conversations.isEmpty {
            emptyState
        } else {
            let grouped = filteredGrouped
            if grouped.isEmpty {
                noMatchState
            } else {
                listBody(grouped: grouped)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .frame(width: 48, height: 48)
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            Text("No conversations yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Start chatting and your history\nwill appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No matching conversations")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func confirmDelete(_ conv: Conversation) {
        confirmDelete(ids: [conv.id])
    }

    /// 删除确认（单条与批量共用）。多选时只确认一次。
    private func confirmDelete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        if ids.count == 1, let id = ids.first,
           let conv = conversationStore.conversations.first(where: { $0.id == id }) {
            alert.messageText = String(localized: "Delete Conversation")
            alert.informativeText = "Are you sure you want to delete \"\(conv.title)\"? This cannot be undone."
        } else {
            alert.messageText = String(localized: "Delete Conversations")
            alert.informativeText = String(localized: "This cannot be undone.")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            conversationStore.delete(ids)
            selection.removeAll()
        }
    }

    /// 原生 `List`：多选（⌘/⇧ 点击）、行内左右滑动操作、右键菜单、Delete 键删除
    /// 全部由系统提供——此前是 ScrollView + 自绘卡片，这些一个都没有。
    private func listBody(grouped: [HistoryGroup]) -> some View {
        List(selection: $selection) {
            ForEach(grouped) { group in
                Section {
                    ForEach(group.items) { conv in
                        ConversationRow(
                            conversation: conv,
                            isCurrent: conv.id == sessionStore.conversationId,
                            isRenaming: renamingID == conv.id,
                            onRename: { newTitle in
                                conversationStore.rename(conv.id, to: newTitle)
                                if renamingID == conv.id { renamingID = nil }
                            },
                            onBeginRename: { renamingID = conv.id },
                            onEndRename: { if renamingID == conv.id { renamingID = nil } }
                        )
                        .tag(conv.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                confirmDelete(conv)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                renamingID = conv.id
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(appAccent)
                        }
                        .contextMenu {
                            Button("Open") { onSelect(conv.id) }
                            Button("Rename") { renamingID = conv.id }
                            Divider()
                            Button("Delete", role: .destructive) { confirmDelete(conv) }
                        }
                    }
                } header: {
                    Text(group.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }
            }
        }
        .listStyle(.inset)
        .onDeleteCommand {
            // 键盘 Delete：有选中就删选中的，否则删当前高亮的（List 会选中它）
            if !selection.isEmpty { confirmDelete(ids: selection) }
        }
    }

    // MARK: - Grouping / filtering

    private var filteredGrouped: [HistoryGroup] {
        // 搜索词变化 → 重置缓存;会话列表变化(count 或最新 updatedAt)→ 失效。
        let stamp = "\(conversationStore.conversations.count)-\(conversationStore.conversations.first?.updatedAt.timeIntervalSince1970 ?? 0)"
        let key = debouncedQuery
        if filterCache.key != key || filterCache.stamp != stamp {
            let filtered: [Conversation]
            if key.isEmpty {
                filtered = conversationStore.conversations
            } else {
                filtered = conversationStore.conversations.filter { conv in
                    if conv.title.localizedCaseInsensitiveContains(key) { return true }
                    return conv.messages.contains { message in
                        message.content?.localizedCaseInsensitiveContains(key) == true
                    }
                }
            }
            filterCache.out = filtered
            filterCache.key = key
            filterCache.stamp = stamp
        }
        let filtered = filterCache.out

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday)!

        var today: [Conversation] = []
        var yesterday: [Conversation] = []
        var thisWeek: [Conversation] = []
        var older: [Conversation] = []

        for conv in filtered {
            if conv.updatedAt >= startOfToday {
                today.append(conv)
            } else if conv.updatedAt >= startOfYesterday {
                yesterday.append(conv)
            } else if conv.updatedAt >= startOfWeek {
                thisWeek.append(conv)
            } else {
                older.append(conv)
            }
        }

        var groups: [HistoryGroup] = []
        if !today.isEmpty { groups.append(.init(title: String(localized: "Today"), items: today)) }
        if !yesterday.isEmpty { groups.append(.init(title: String(localized: "Yesterday"), items: yesterday)) }
        if !thisWeek.isEmpty { groups.append(.init(title: String(localized: "This Week"), items: thisWeek)) }
        if !older.isEmpty { groups.append(.init(title: String(localized: "Older"), items: older)) }
        return groups
    }
}

// MARK: - Models

private struct HistoryGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [Conversation]
}

// MARK: - Row

private struct ConversationRow: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let conversation: Conversation
    let isCurrent: Bool
    /// 是否处于行内重命名（由滑动/右键/双击触发，状态在父视图里，才能被这些入口设置）。
    let isRenaming: Bool
    let onRename: (String) -> Void
    let onBeginRename: () -> Void
    let onEndRename: () -> Void

    @State private var isEditing = false
    @State private var editTitle = ""
    @FocusState private var isEditFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(iconFill)
                    .frame(width: 18, height: 18)
                Image(systemName: isCurrent ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(iconForeground)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Title", text: $editTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .focused($isEditFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                } else {
                    Text(conversation.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 4) {
                    Text(messageCountText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(conversation.updatedAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // 不在行里自绘底色、也不放 hover 按钮：原生 List 画高亮，
        // 删除走滑动 / 右键 / Delete 键（用户："hover 的删除按钮可以去掉了"）。
        .onDisappear { cancelRename() }
        // nsui gesture for double-click (NSView-style)
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, pressing: { _ in }, perform: {})
        .background(
            DoubleClickHandler { onBeginRename() }
        )
        .onChange(of: isEditFocused) { _, focused in
            if !focused && isEditing { commitRename() }
        }
        .onChange(of: isRenaming) { _, wanted in
            // 滑动/右键/双击都只是把 isRenaming 置真，这里统一进入编辑态。
            if wanted, !isEditing { beginRename() }
        }
    }

    private func beginRename() {
        editTitle = conversation.title
        isEditing = true
        isEditFocused = true
    }

    private func commitRename() {
        guard isEditing else { return }
        isEditing = false
        onEndRename()
        let trimmed = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != conversation.title {
            onRename(trimmed)
        }
    }

    private func cancelRename() {
        isEditing = false
        editTitle = ""
        onEndRename()
    }

    private var messageCountText: String {
        conversation.messages.count == 1
            ? "1 message"
            : "\(conversation.messages.count) messages"
    }

    private var iconFill: Color {
        isCurrent
            ? appAccent.opacity(0.18)
            : Color(nsColor: .controlBackgroundColor).opacity(0.6)
    }

    private var iconForeground: Color {
        isCurrent ? appAccent : Color.secondary
    }

}

// MARK: - DoubleClickHandler (NSViewRepresentable)

/// Detects double-click on the hosting view and forwards it to the closure.
fileprivate struct DoubleClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> DoubleClickView {
        DoubleClickView(action: action)
    }
    func updateNSView(_ nsView: DoubleClickView, context: Context) {
        nsView.action = action
    }

    final class DoubleClickView: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { action() }
            super.mouseDown(with: event)
        }
    }
}
