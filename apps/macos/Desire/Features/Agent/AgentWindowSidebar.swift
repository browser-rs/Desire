import SwiftUI

/// 独立 Agent 窗口两栏布局的**左侧会话列表**（2026-10-10）。
/// 定位是轻量切换器：标题搜索 + 按时间分组的原生 `List`（选中态跟手、
/// 右键删除、Delete 键删除）；多选/重命名/正文级搜索仍走面板头部的历史
/// 页（clock 入口），两边不重复造。
struct AgentWindowSidebar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var sessionStore: AgentSessionStore
    var onNewChat: () -> Void

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            searchField
            if conversationStore.conversations.isEmpty {
                emptyState
            } else if groups.isEmpty {
                noMatchState
            } else {
                conversationList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Text("Conversations")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            HoverIcon(systemName: "plus.bubble", action: onNewChat, help: "New chat")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search conversations", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - List

    /// 侧栏搜索只按标题过滤（轻量切换器口径）；正文级搜索在历史页。
    private var filtered: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return conversationStore.conversations }
        return conversationStore.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [AgentHistoryGroup] {
        AgentHistoryGroup.buckets(filtered)
    }

    /// 原生 `List(selection:)`：选中态直接绑定"当前会话"——点行即切换，
    /// 其他宿主装载了别的会话时高亮也跟着走。行不自绘高亮（系统画）。
    private var conversationList: some View {
        List(
            selection: Binding<UUID?>(
                get: { sessionStore.conversationId },
                set: { id in
                    if let id, id != sessionStore.conversationId {
                        sessionStore.loadConversation(id)
                    }
                }
            )
        ) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { conv in
                        AgentWindowSidebarRow(
                            conversation: conv,
                            isCurrent: conv.id == sessionStore.conversationId
                        )
                        .tag(conv.id)
                        .contextMenu {
                            Button("Open") { sessionStore.loadConversation(conv.id) }
                            Divider()
                            Button("Delete", role: .destructive) { confirmDelete(conv) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            // 键盘 Delete：删当前会话（与历史页同款确认弹窗）。
            if let id = sessionStore.conversationId,
               let conv = conversationStore.conversations.first(where: { $0.id == id }) {
                confirmDelete(conv)
            }
        }
    }

    private func confirmDelete(_ conv: Conversation) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete Conversation")
        alert.informativeText = "Are you sure you want to delete \"\(conv.title)\"? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            conversationStore.delete([conv.id])
            // 删的是面板正在显示的会话 → 面板重置回空态（防止残留下回合写回复活）。
            sessionStore.handleConversationsDeleted([conv.id])
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No conversations yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text("No matching conversations")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

/// 侧栏行：标题 + 条数/相对时间两行紧凑布局。选中高亮由系统 List 画，
/// 行内不自绘底色（原生列表行禁令）。
private struct AgentWindowSidebarRow: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let conversation: Conversation
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isCurrent ? appAccent : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text("\(conversation.messages.count) 条")
                    Text(verbatim: "·")
                    Text(conversation.updatedAt, style: .relative)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
