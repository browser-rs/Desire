import SwiftUI

/// 会话列表（Tab「会话」）：按最近更新分组、滑动重命名/删除。
/// 重做要点：改用 `insetGrouped` 原生分组（原来是自绘卡片 + 隐藏分隔线），
/// 行内信息补上「最近更新时间」与消息数，左滑两个方向分别对应删除与重命名。
struct SessionListView: View {
    @EnvironmentObject var client: RemoteClient
    /// 点开一条会话（由上层 push 对话页）
    var onOpen: (String) -> Void
    /// 新建会话并进入对话页
    var onNew: () -> Void
    @State private var renameTarget: RemoteClient.RemoteSessionInfo?
    @State private var renameText = ""
    @State private var pendingDelete: RemoteClient.RemoteSessionInfo?

    private var groupedSessions: [(String, [RemoteClient.RemoteSessionInfo])] {
        let calendar = Calendar.current
        let now = Date()
        var groups: [String: [RemoteClient.RemoteSessionInfo]] = [:]
        let order = ["今天", "昨天", "本周", "更早"]

        for session in client.sessions {
            guard let date = session.dateValue else {
                groups["更早", default: []].append(session)
                continue
            }
            if calendar.isDateInToday(date) {
                groups["今天", default: []].append(session)
            } else if calendar.isDateInYesterday(date) {
                groups["昨天", default: []].append(session)
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                groups["本周", default: []].append(session)
            } else {
                groups["更早", default: []].append(session)
            }
        }

        return order.compactMap { key in
            groups[key].map { (key, $0) }
        }
    }

    var body: some View {
        Group {
            if client.sessions.isEmpty {
                ScrollView {
                    emptyState
                }
                .refreshable { client.requestSessions() }
            } else {
                list
            }
        }
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    onNew()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .medium))
                }
                .accessibilityLabel("新建会话")
            }
        }
        // 进页即拉一次；从对话页返回时也刷新（列表一直存在，`.task` 不会重跑，
        // 而这段对话的标题/条数期间可能已经变了）
        .onAppear {
            client.requestSessions()
            // 顺带强制一帧快照，避免本页与对话页的状态各自停在旧值
            client.requestSync()
        }
        .alert("重命名会话", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("会话名称", text: $renameText)
            Button("保存") {
                if let target = renameTarget { client.renameSession(target.id, to: renameText) }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .alert("删除会话", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let target = pendingDelete { client.deleteSession(target.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "「\($0.label)」将从 Mac 上删除，无法恢复。" } ?? "")
        }
    }

    private var emptyState: some View {
        DesireEmptyState(
            icon: "bubble.left.and.bubble.right",
            title: "还没有会话",
            message: client.desktopOnline
                ? "在 Mac 上开始一轮对话，或点右上角新建。"
                : "Mac 当前离线，连上后这里会显示它的对话。")
    }

    private var list: some View {
        List {
            ForEach(groupedSessions, id: \.0) { section, items in
                Section {
                    ForEach(items) { session in
                        row(session)
                    }
                } header: {
                    DesireSectionHeader(title: section)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestSessions() }
    }

    private func row(_ session: RemoteClient.RemoteSessionInfo) -> some View {
        let isSelected = session.id == client.selectedSessionID
        return Button {
            onOpen(session.id)
        } label: {
            HStack(spacing: 12) {
                DesireIconBadge(
                    icon: "bubble.left.fill",
                    tint: isSelected ? DesireUI.brand : .secondary,
                    filled: isSelected)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.label)
                            .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if session.busy {
                            Text("工作中")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                        if isSelected {
                            Text("当前")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesireUI.brand)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DesireUI.brand.opacity(0.14)))
                        }
                    }
                    Text(Self.subtitle(for: session))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = session
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                renameText = session.label
                renameTarget = session
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(DesireUI.brand)
        }
    }

    private static func subtitle(for session: RemoteClient.RemoteSessionInfo) -> String {
        var parts = ["\(session.count) 条消息"]
        if let date = session.dateValue {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append(formatter.localizedString(for: date, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }
}
