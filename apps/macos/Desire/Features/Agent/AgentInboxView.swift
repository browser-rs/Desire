import AppKit
import Combine
import SwiftUI

/// 收件箱页（v26）：Agent 窗口侧栏新目的地——「等你处理」+「变化与结果」。
/// 数据经 `AgentInboxCollector` 从各 store 实时收集、`AgentInbox.build`（纯
/// 函数）分节；同一份构建逻辑同时供桥 `GET /inbox` 与离屏快照使用。
struct AgentInboxView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var conversationStore: ConversationStore
    @ObservedObject private var scheduler = AgentScheduler.shared
    @ObservedObject private var watchStore = PageWatchStore.shared
    @ObservedObject private var promotionStore = PromotionStore.shared
    @ObservedObject private var notifications = ProactiveNotificationStore.shared

    var onBack: () -> Void = {}
    /// 打开某会话（nil = 只回聊天列）。
    var onOpenConversation: (UUID?) -> Void = { _ in }
    var onOpenOperations: () -> Void = {}
    var onOpenTasks: () -> Void = {}

    @State private var flushNote: String?
    /// 批处理（v0.7.22）：选择模式 + 批量条。
    @ObservedObject private var dismissals = AgentInboxDismissalStore.shared
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    private var sections: [AgentInbox.Section] {
        let store = AgentInboxDismissalStore.shared
        return AgentInbox.build(AgentInboxCollector.liveInputs(conversationStore: conversationStore),
                                hidden: { store.isHidden($0) })
            .filter { !$0.items.isEmpty }
    }

    private var totalItems: Int { sections.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selectedIDs.isEmpty {
                batchBar
            }
        }
    }

    /// 批量条（选择模式 + 有选中项）：稍后 1 小时 / 到明天 09:00 / 忽略。
    private var batchBar: some View {
        HStack(spacing: 10) {
            Text(String(localized: "Selected") + " \(selectedIDs.count)")
                .font(.system(size: 11.5, weight: .medium))
            Spacer()
            Button(String(localized: "Snooze 1 Hour")) {
                dismissals.snooze(Array(selectedIDs), until: Date().addingTimeInterval(3600))
                finishBatch()
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            Button(String(localized: "Tomorrow")) {
                let calendar = Calendar.current
                let tomorrow = Date().addingTimeInterval(86_400)
                let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                dismissals.snooze(Array(selectedIDs), until: nine)
                finishBatch()
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            Button(String(localized: "Ignore")) {
                dismissals.ignore(Array(selectedIDs))
                finishBatch()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func finishBatch() {
        selectedIDs.removeAll()
        isSelecting = false
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "tray")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Inbox")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let flushNote {
                Text(flushNote)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(appAccent)
            } else if totalItems > 0 {
                Text("\(totalItems) item(s)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            }
            if dismissals.hiddenCount > 0, !isSelecting {
                Button {
                    dismissals.restore()
                } label: {
                    Text(String(localized: "Hidden") + " \(dismissals.hiddenCount) · " + String(localized: "Restore"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(appAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(appAccent.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Restore all ignored / snoozed items")
            }
            if totalItems > 0 {
                Button(isSelecting ? String(localized: "Done") : String(localized: "Select")) {
                    isSelecting.toggle()
                    if !isSelecting { selectedIDs.removeAll() }
                }
                .font(.system(size: 10.5))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    // MARK: - Sections

    private func sectionView(_ section: AgentInbox.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(section.items.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 4) {
                ForEach(section.items) { item in
                    itemRow(item)
                }
            }
        }
    }

    private func itemRow(_ item: AgentInbox.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelecting {
                Image(systemName: selectedIDs.contains(item.id)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selectedIDs.contains(item.id)
                                     ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                    .padding(.top, 1)
            }
            Image(systemName: icon(for: item.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color(for: item.kind))
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            actionButton(for: item)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for item: AgentInbox.Item) -> some View {
        switch item.kind {
        case .interrupted, .unanswered:
            Button(String(localized: "Handle it")) {
                onOpenConversation(item.conversationID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .interaction:
            Button(String(localized: "Handle it")) {
                onOpenOperations()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .heldNotification:
            Button(String(localized: "Flush now")) {
                let flushed = notifications.flushDigest(force: true)
                withAnimation(.transitionNormal) {
                    flushNote = flushed > 0
                        ? String(localized: "Flushed \(flushed)")
                        : String(localized: "Nothing to flush")
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.transitionNormal) { flushNote = nil }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .failedRun:
            Button(String(localized: "Open tasks")) {
                onOpenTasks()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .watchChange:
            EmptyView()
        }
    }

    private func icon(for kind: AgentInbox.Kind) -> String {
        switch kind {
        case .interrupted: return "arrow.clockwise.circle"
        case .unanswered: return "bubble.left.and.bubble.right"
        case .interaction: return "megaphone"
        case .heldNotification: return "bell.badge"
        case .watchChange: return "eye"
        case .failedRun: return "exclamationmark.triangle"
        }
    }

    private func color(for kind: AgentInbox.Kind) -> Color {
        switch kind {
        case .interrupted: return .orange
        case .unanswered: return appAccent
        case .interaction: return appAccent
        case .heldNotification: return .orange
        case .watchChange: return .secondary
        case .failedRun: return .red
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Inbox is empty")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Nothing needs you — no page changes or task results either.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
