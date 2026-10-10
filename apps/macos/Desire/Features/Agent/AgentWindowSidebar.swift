import SwiftUI

/// 独立 Agent 窗口两栏布局的**左侧智能体侧栏**（2026-10-10）。
/// 上半区是目的地导航（任务/技能/记忆/统计/轨迹/能力，带计数徽标），
/// 下半区是会话列表（标题搜索 + 按时间分组的原生 `List`：点行即切换、
/// 右键/Delete 键删除）。多选/重命名/正文级搜索仍走聊天列的历史页
/// （clock 入口），两边不重复造。
struct AgentWindowSidebar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Binding var destination: AgentWindowDestination
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject var sessionStore: AgentSessionStore
    /// 目的地徽标的数据源（任务/技能计数）。
    @ObservedObject private var scheduler = AgentScheduler.shared
    @ObservedObject private var skillStore = SkillStore.shared
    var onNewChat: () -> Void
    /// 从侧栏点会话时把右栏带回聊天列。
    var onActivateChat: () -> Void

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            destinationsSection
            Divider().opacity(0.6)
            conversationsHeader
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
            Text("Agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            HoverIcon(systemName: "plus.bubble", action: onNewChat, help: "New chat")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    // MARK: - Destinations（智能体区）

    private var destinationsSection: some View {
        VStack(spacing: 2) {
            destinationRow(.tasks, icon: "clock.badge.checkmark",
                           label: String(localized: "Tasks"),
                           badge: scheduler.tasks.isEmpty ? nil : "\(scheduler.tasks.count)")
            destinationRow(.skills, icon: "puzzlepiece.extension",
                           label: String(localized: "Skills"),
                           badge: skillStore.skills.isEmpty ? nil : "\(skillStore.skills.count)")
            destinationRow(.memory, icon: "brain.head.profile",
                           label: String(localized: "Memory"))
            destinationRow(.stats, icon: "chart.bar.xaxis",
                           label: String(localized: "Usage"))
            destinationRow(.trace, icon: "point.topleft.down.to.point.bottomright.curvepath",
                           label: String(localized: "Trace"))
            destinationRow(.capabilities, icon: "sparkles.rectangle.stack",
                           label: String(localized: "Capabilities"))
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func destinationRow(
        _ target: AgentWindowDestination,
        icon: String,
        label: String,
        badge: String? = nil
    ) -> some View {
        let isActive = destination == target
        return Button {
            withAnimation(.transitionNormal) {
                destination = target
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? appAccent : Color.secondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? appAccent : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? appAccent.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Conversations（会话区）

    private var conversationsHeader: some View {
        HStack(spacing: 6) {
            Text("Conversations")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(conversationStore.conversations.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
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
        .padding(.vertical, 6)
    }

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
                    // nil = List 侧的取消选择（内容刷新时会来），别当"点行了"。
                    guard let id else { return }
                    if id != sessionStore.conversationId {
                        sessionStore.loadConversation(id)
                    }
                    onActivateChat()
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
                            Button("Open") {
                                sessionStore.loadConversation(conv.id)
                                onActivateChat()
                            }
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
