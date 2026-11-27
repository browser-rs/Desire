import SwiftUI

/// 实时标签页（v0.8.80 批 4）：Mac 当前窗口的标签、分组与窗口；
/// 切换 / 关闭 / 搜索 / 移到另一个窗口。
struct RemoteTabsView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var query = ""

    private var frame: RemoteTabsFrame? { client.tabsFrame }

    private var filtered: [RemoteTabItem] {
        guard let tabs = frame?.tabs else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return tabs }
        return tabs.filter {
            $0.title.lowercased().contains(trimmed) || $0.url.lowercased().contains(trimmed)
        }
    }

    private var otherWindows: [RemoteWindowInfo] {
        (frame?.windows ?? []).filter { !$0.active }
    }

    var body: some View {
        List {
            if let frame, !frame.windows.isEmpty {
                Section {
                    ForEach(frame.windows) { window in
                        HStack(spacing: 8) {
                            Image(systemName: window.active ? "macwindow" : "macwindow.on.rectangle")
                                .foregroundStyle(window.active ? DesireUI.brand : .secondary)
                            Text(window.title)
                                .lineLimit(1)
                            Spacer()
                            Text("\(window.tabs) 个标签")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    DesireSectionHeader(title: "窗口", subtitle: "点标签可切换；长按/右滑可关闭或移动")
                }
            }

            if filtered.isEmpty {
                DesireEmptyState(icon: "rectangle.stack", title: "没有标签",
                                 message: query.isEmpty ? "Mac 的当前窗口没有标签。" : "没有匹配的标签。")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(filtered) { tab in
                        row(tab)
                    }
                } header: {
                    DesireSectionHeader(title: "标签 · \(filtered.count)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("标签页")
        .searchable(text: $query, prompt: "搜索标题或网址")
        .onAppear { client.requestTabs() }
        .refreshable { client.requestTabs() }
    }

    private func row(_ tab: RemoteTabItem) -> some View {
        Button {
            client.tabAction("select", id: tab.id)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: tab.selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(tab.selected ? DesireUI.brand : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(tab.title.isEmpty ? "无标题" : tab.title)
                            .font(.subheadline.weight(tab.selected ? .semibold : .regular))
                            .lineLimit(1)
                        if tab.loading {
                            ProgressView().controlSize(.mini)
                        }
                        if tab.playing {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2).foregroundStyle(.green)
                        }
                        if tab.muted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if tab.incognito {
                            Image(systemName: "eye.slash")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text(tab.url)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if let group = tab.group {
                        Text(group)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesireUI.brand.opacity(0.12)))
                            .foregroundStyle(DesireUI.brand)
                    }
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                client.tabAction("close", id: tab.id)
            } label: {
                Label("关闭", systemImage: "xmark")
            }
        }
        .contextMenu {
            Button("在 Mac 上切换") { client.tabAction("select", id: tab.id) }
            Button("关闭", role: .destructive) { client.tabAction("close", id: tab.id) }
            if !otherWindows.isEmpty {
                Menu("移到窗口") {
                    ForEach(otherWindows) { window in
                        Button(window.title) {
                            client.tabAction("move", id: tab.id, window: window.id)
                        }
                    }
                }
            }
        }
    }
}
