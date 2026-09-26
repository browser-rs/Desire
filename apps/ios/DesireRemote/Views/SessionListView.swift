import SwiftUI

/// 会话列表（Menu 磁贴「会话」push 进入）：
/// 按最近更新分组（今天/昨天/本周/更早），左滑删除、长按重命名。
struct SessionListView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var renameTarget: RemoteClient.RemoteSessionInfo?
    @State private var renameText = ""

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
                emptyState
            } else {
                sessionsList
            }
        }
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { client.requestSessions() }
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
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 8) {
                Text("还没有会话")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("在 Mac 上开始一轮对话，\n或点右上角新建。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionsList: some View {
        List {
            ForEach(groupedSessions, id: \.0) { section, items in
                Section {
                    ForEach(items) { session in
                        SessionRowCard(
                            session: session,
                            isSelected: session.id == client.selectedSessionID
                        )
                        .contentShape(Rectangle())
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowSeparator(.hidden)
                        .onTapGesture {
                            client.selectSession(session.id)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                client.deleteSession(session.id)
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
                            .tint(RootView.brand)
                        }
                    }
                } header: {
                    Text(section)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .padding(.top, 16)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct SessionRowCard: View {
    let session: RemoteClient.RemoteSessionInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isSelected ? RootView.brand.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? RootView.brand : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.label)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label("\(session.count)", systemImage: "text.bubble.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if session.busy {
                        Text("工作中")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
