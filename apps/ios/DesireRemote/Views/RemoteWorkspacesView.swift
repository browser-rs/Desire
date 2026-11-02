import SwiftUI

/// 工作区（v0.8.38 批二）：Mac 上保存的命名标签组，手机上浏览并一键恢复。
struct RemoteWorkspacesView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var pending: RemoteWorkspaceItem?
    @State private var searchText = ""

    private var filtered: [RemoteWorkspaceItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return client.workspaces }
        return client.workspaces.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if client.workspaces.isEmpty {
                DesireEmptyState(
                    icon: "rectangle.stack",
                    title: "还没有工作区",
                    message: "在 Mac 的 Workspaces 面板保存当前标签组，或在 File 菜单里「Hand Off Tabs」，这里就会出现。")
                    .listRowBackground(Color.clear)
            } else if filtered.isEmpty {
                Text("没有匹配 \(searchText) 的工作区")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                Section {
                    ForEach(filtered) { workspace in
                        Button {
                            pending = workspace
                        } label: {
                            HStack(spacing: 12) {
                                DesireIconBadge(icon: "rectangle.stack", size: 38)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workspace.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text("\(workspace.tabCount) 个标签页")
                                        Text(Date(timeIntervalSince1970: workspace.savedAt),
                                             style: .date)
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "macwindow")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    DesireSectionHeader(
                        title: "已保存",
                        subtitle: "恢复会替换 Mac 当前窗口的标签页")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("工作区")
        .searchable(text: $searchText, prompt: "按名称过滤")
        .onAppear { client.requestWorkspaces() }
        .refreshable { client.requestWorkspaces() }
        .confirmationDialog(
            pending.map { "在 Mac 上恢复「\($0.name)」？" } ?? "恢复工作区？",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let workspace = pending {
                Button("恢复 \(workspace.tabCount) 个标签页", role: .destructive) {
                    client.openWorkspace(id: workspace.id)
                    pending = nil
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: {
            Text("Mac 当前窗口的标签页会被这组标签替换。")
        }
    }
}
