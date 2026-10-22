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
    @State private var retryNote: String?
    /// 批处理（v0.7.22）：选择模式 + 批量条；v0.7.27 补批量重试与类型筛选。
    @ObservedObject private var dismissals = AgentInboxDismissalStore.shared
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    /// 类型筛选（v0.7.27）：点击 chip 隐藏/显示一类条目（仅 UI 状态）。
    @State private var hiddenKinds: Set<AgentInbox.Kind> = []

    private var allSections: [AgentInbox.Section] {
        let store = AgentInboxDismissalStore.shared
        return AgentInbox.build(AgentInboxCollector.liveInputs(conversationStore: conversationStore),
                                hidden: { store.isHidden($0) })
            .filter { !$0.items.isEmpty }
    }

    private var sections: [AgentInbox.Section] {
        allSections.compactMap { section in
            let items = section.items.filter { !hiddenKinds.contains($0.kind) }
            return items.isEmpty ? nil
                : AgentInbox.Section(id: section.id, title: section.title, items: items)
        }
    }

    private var presentKinds: [(kind: AgentInbox.Kind, count: Int)] {
        let items = allSections.flatMap(\.items)
        return AgentInbox.Kind.allCases.compactMap { kind in
            let count = items.filter { $0.kind == kind }.count
            return count > 0 ? (kind, count) : nil
        }
    }

    private var totalItems: Int { sections.reduce(0) { $0 + $1.items.count } }

    /// 选中条目里可重跑的任务名（failedRun）。
    private var selectedRunTaskNames: [String] {
        allSections.flatMap(\.items)
            .filter { selectedIDs.contains($0.id) }
            .compactMap { AgentInbox.taskName(fromItemID: $0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if presentKinds.count > 1 || !hiddenKinds.isEmpty {
                kindFilterBar
                Divider().opacity(0.4)
            }
            if sections.isEmpty {
                if allSections.isEmpty {
                    emptyState
                } else {
                    filteredEmptyState
                }
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
            if !selectedRunTaskNames.isEmpty {
                Button(String(localized: "Retry tasks")) {
                    retrySelectedTasks()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(appAccent)
            }
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

    /// 批量重试失败任务（v0.7.27）：`fireNow` 逐任务触发；旧失败条目先稍后
    /// 1 小时隐藏（否则重跑期间它仍躺在收件箱里，看起来像没生效）。
    private func retrySelectedTasks() {
        let names = Set(selectedRunTaskNames)
        var retried = 0
        for name in names where scheduler.fireNow(named: name) {
            retried += 1
        }
        let runIDs = Array(selectedIDs.filter { AgentInbox.taskName(fromItemID: $0) != nil })
        if !runIDs.isEmpty {
            dismissals.snooze(runIDs, until: Date().addingTimeInterval(3600))
        }
        showRetryNote(String(localized: "Retried \(retried) task(s)"))
        finishBatch()
    }

    private func showRetryNote(_ text: String) {
        withAnimation(.transitionNormal) { retryNote = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.transitionNormal) { retryNote = nil }
        }
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
            if let note = retryNote ?? flushNote {
                Text(note)
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

    /// 类型筛选（v0.7.27）：只在出现 ≥2 类时显示；点击切换该类的显隐。
    private var kindFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(presentKinds, id: \.kind) { entry in
                    let active = !hiddenKinds.contains(entry.kind)
                    Button {
                        if active {
                            hiddenKinds.insert(entry.kind)
                        } else {
                            hiddenKinds.remove(entry.kind)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: icon(for: entry.kind))
                                .font(.system(size: 9))
                            Text(kindLabel(entry.kind))
                                .font(.system(size: 10, weight: .medium))
                            Text("\(entry.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(active ? appAccent.opacity(0.12) : Color.clear))
                        .overlay(Capsule().stroke(active ? appAccent.opacity(0.35)
                                                         : Color.secondary.opacity(0.25),
                                                  lineWidth: 0.7))
                        .foregroundStyle(active ? AnyShapeStyle(appAccent)
                                                : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help(active ? "Hide this type" : "Show this type")
                }
                if !hiddenKinds.isEmpty {
                    Button(String(localized: "Show all")) {
                        hiddenKinds.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func kindLabel(_ kind: AgentInbox.Kind) -> String {
        switch kind {
        case .interrupted: return String(localized: "Interrupted")
        case .unanswered: return String(localized: "Waiting")
        case .interaction: return String(localized: "Interactions")
        case .heldNotification: return String(localized: "Held")
        case .watchChange: return String(localized: "Watches")
        case .failedRun: return String(localized: "Failed runs")
        case .jobAttention: return String(localized: "Jobs")
        }
    }

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
        .contextMenu {
            if item.kind == .failedRun, let name = AgentInbox.taskName(fromItemID: item.id) {
                Button(String(localized: "Retry task")) {
                    let ok = scheduler.fireNow(named: name)
                    dismissals.snooze([item.id], until: Date().addingTimeInterval(3600))
                    showRetryNote(ok
                        ? String(localized: "Retried task “\(name)”")
                        : String(localized: "Task “\(name)” is not available"))
                }
            }
            Button(String(localized: "Snooze 1 Hour")) {
                dismissals.snooze([item.id], until: Date().addingTimeInterval(3600))
            }
            Button(String(localized: "Ignore")) {
                dismissals.ignore([item.id])
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
        case .jobAttention:
            Button(String(localized: "Open Jobs")) {
                NotificationCenter.default.post(name: .openJobsPanel, object: nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
        case .jobAttention: return "square.stack.3d.up"
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
        case .jobAttention: return appAccent
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

    /// 有内容但被类型筛选全部隐藏。
    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No items match the filter")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Button(String(localized: "Show all")) {
                hiddenKinds.removeAll()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(appAccent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
