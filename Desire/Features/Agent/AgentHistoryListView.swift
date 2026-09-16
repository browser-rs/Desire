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

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            content
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
        let alert = NSAlert()
        alert.messageText = "Delete Conversation"
        alert.informativeText = "Are you sure you want to delete \"\(conv.title)\"? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            conversationStore.delete(conv.id)
        }
    }

    private func listBody(grouped: [HistoryGroup]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(grouped) { group in
                    section(title: group.title, items: group.items)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }

    private func section(title: String, items: [Conversation]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            VStack(spacing: 0) {
                ForEach(items) { conv in
                    ConversationRow(
                        conversation: conv,
                        isCurrent: conv.id == sessionStore.conversationId,
                        onSelect: { onSelect(conv.id) },
                        onDelete: { confirmDelete(conv) },
                        onRename: { newTitle in conversationStore.rename(conv.id, to: newTitle) }
                    )
                    if conv.id != items.last?.id {
                        Divider()
                            .padding(.leading, 36)
                            .opacity(0.5)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Grouping / filtering

    private var filteredGrouped: [HistoryGroup] {
        let filtered: [Conversation] = {
            guard !searchText.isEmpty else {
                return conversationStore.conversations
            }
            return conversationStore.conversations.filter { conv in
                conv.title.localizedCaseInsensitiveContains(searchText)
            }
        }()

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
        if !today.isEmpty { groups.append(.init(title: "Today", items: today)) }
        if !yesterday.isEmpty { groups.append(.init(title: "Yesterday", items: yesterday)) }
        if !thisWeek.isEmpty { groups.append(.init(title: "This Week", items: thisWeek)) }
        if !older.isEmpty { groups.append(.init(title: "Older", items: older)) }
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
    let conversation: Conversation
    let isCurrent: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void

    @State private var isHovering = false
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

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(Color.red.opacity(0.10))
                        )
                }
                .buttonStyle(.plain)
                .help("Delete conversation")
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(.hoverFast, value: isHovering)
        .onDisappear { cancelRename() }
        // nsui gesture for double-click (NSView-style)
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity, pressing: { _ in }, perform: {})
        .background(
            DoubleClickHandler { beginRename() }
        )
        .onChange(of: isEditFocused) { _, focused in
            if !focused && isEditing { commitRename() }
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
        let trimmed = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != conversation.title {
            onRename(trimmed)
        }
    }

    private func cancelRename() {
        isEditing = false
        editTitle = ""
    }

    private var messageCountText: String {
        conversation.messages.count == 1
            ? "1 message"
            : "\(conversation.messages.count) messages"
    }

    private var iconFill: Color {
        isCurrent
            ? Color.accentColor.opacity(0.18)
            : Color(nsColor: .controlBackgroundColor).opacity(0.6)
    }

    private var iconForeground: Color {
        isCurrent ? Color.accentColor : Color.secondary
    }

    private var rowFill: Color {
        if isCurrent { return Color.accentColor.opacity(0.08) }
        if isHovering { return Color(nsColor: .controlBackgroundColor).opacity(0.6) }
        return Color.clear
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
