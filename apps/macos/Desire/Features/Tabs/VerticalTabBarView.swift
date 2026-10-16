import AppKit
import Combine
import SwiftUI
import os

/// 垂直标签栏（0.6.3）：侧栏形态的标签列表，与顶部标签栏共存可切换。
///
/// - 顺序**即** `tabManager.tabs` 的顺序（顶部栏/`/state` 同源，不重排）；
///   分组信息读 `TabGroupStore`（组名/颜色/折叠），固定标签在顶部区。
/// - 拖拽排序走原生 `List` 的 `onMove`（→ `moveTab`）。
/// - 小窗自动折叠：宽度 < 120pt 时收成图标列（图标 22pt 居中）。
struct VerticalTabBarView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var tabGroupStore: TabGroupStore
    @ObservedObject var settings: Settings
    let selectedIndex: Int
    let isFullScreen: Bool
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    let onMoveTab: (Int, Int) -> Void
    let onReloadTab: (Tab) -> Void
    let onCopyTabURL: (Tab) -> Void
    let onToggleAudioMute: (Int) -> Void
    let onTogglePin: (Int) -> Void
    let onCloseOtherTabs: (Int) -> Void
    let onCloseTabsToRight: (Int) -> Void
    let onRemoveFromGroup: (UUID) -> Void
    /// 标签组全套操作（v0.7.18 UI 收口）：与顶部栏同款的折叠行 + 右键菜单
    /// （重命名 / 折叠 / 删组 / 移出组 / 加入组）——此前侧栏只有"移出组"
    /// 一条，组名与折叠态也没体现。
    let tabGroups: [TabGroup]
    let onToggleGroupCollapse: (UUID) -> Void
    let onDeleteGroup: (UUID) -> Void
    let onAddToGroup: (UUID, UUID) -> Void
    let onRenameGroup: (UUID, String) -> Void
    /// 新建组并把该标签入组（侧栏模式下顶栏是隐藏的——没有这个入口
    /// 就完全无法从 UI 建组；与顶栏的 "New Group…" 同一条 prompt 路径）。
    let onCreateGroup: (Int) -> Void
    let tabGroupColor: (UUID) -> Color?

    @Environment(\.appAccent) private var appAccent
    /// 宽度持久化（分栏拖动手柄由外层 HSplitView 提供）。
    @AppStorage("verticalTabBar.width") private var width: Double = 200
    @State private var compact = false

    private let compactThreshold: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < compactThreshold
            let _ = Task { @MainActor in
                if compact != isCompact { compact = isCompact }
            }
            Group {
                if isCompact {
                    compactList
                } else {
                    fullList
                }
            }
        }
        .frame(minWidth: 56, idealWidth: width, maxWidth: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 完整列表

    private var fullList: some View {
        List {
            // 折叠组与顶部栏一致：组内标签收起、渲染成一行"组名 + 数量"
            // （点击展开；右键 = 展开/重命名/删组）。
            let collapsedGroups = tabGroups.filter { $0.isCollapsed }
                .filter { group in tabManager.tabs.contains { group.tabIds.contains($0.id) } }
            let collapsedTabIDs = Set(collapsedGroups.flatMap(\.tabIds))
            let pinned = tabManager.tabs.enumerated().filter { $0.element.isPinned && !collapsedTabIDs.contains($0.element.id) }
            if !pinned.isEmpty {
                Section("固定") {
                    ForEach(pinned, id: \.element.id) { pair in
                        row(index: pair.offset, tab: pair.element)
                    }
                    .onMove { source, target in
                        onMoveTab(source.first ?? 0, target)
                    }
                }
            }
            Section("标签页") {
                ForEach(collapsedGroups) { group in
                    collapsedGroupRow(group)
                }
                ForEach(Array(tabManager.tabs.enumerated().filter {
                    !$0.element.isPinned && !collapsedTabIDs.contains($0.element.id)
                }), id: \.element.id) { pair in
                    row(index: pair.offset, tab: pair.element)
                }
                .onMove { source, target in
                    onMoveTab(source.first ?? 0, target)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// 折叠组一行（点击展开——与顶部栏胶囊同语义）。
    private func collapsedGroupRow(_ group: TabGroup) -> some View {
        HStack(spacing: 8) {
            if let color = tabGroupColor(group.tabIds.first ?? UUID()) {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(group.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(group.tabIds.count)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggleGroupCollapse(group.id) }
        .help(String(localized: "Expand Group"))
        .contextMenu {
            Button("Open Group") { onToggleGroupCollapse(group.id) }
            Button("Rename Group…") {
                TabGroupPrompts.presentRename(group: group) { newName in
                    onRenameGroup(group.id, newName)
                }
            }
            Button("Delete Group") { onDeleteGroup(group.id) }
        }
    }

    // MARK: - 图标列（小窗）

    private var compactList: some View {
        ScrollView {
            VStack(spacing: 4) {
                // 折叠组：一个小按钮（色点 + 堆叠图标），点击展开——与完整
                // 列表的折叠行同语义；组内标签随之收纳。
                let collapsedGroups = tabGroups.filter { $0.isCollapsed }
                    .filter { group in tabManager.tabs.contains { group.tabIds.contains($0.id) } }
                let collapsedTabIDs = Set(collapsedGroups.flatMap(\.tabIds))
                ForEach(collapsedGroups) { group in
                    Button {
                        onToggleGroupCollapse(group.id)
                    } label: {
                        VStack(spacing: 2) {
                            if let color = tabGroupColor(group.tabIds.first ?? UUID()) {
                                Circle().fill(color).frame(width: 6, height: 6)
                            }
                            Image(systemName: "rectangle.stack.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                        }
                        .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help(group.name)
                }
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                    if collapsedTabIDs.contains(tab.id) {
                        EmptyView()
                    } else {
                        Button {
                            onSelectTab(index)
                        } label: {
                            VStack(spacing: 2) {
                                if let color = tabGroupColor(tab.id) {
                                    Circle().fill(color).frame(width: 6, height: 6)
                                }
                                faviconPlaceholder(tab)
                                    .overlay(alignment: .topTrailing) {
                                        if tab.audioMuted {
                                            Image(systemName: "speaker.slash.fill")
                                                .font(.system(size: 7))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                            }
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(index == selectedIndex ? appAccent.opacity(0.18) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(tab.displayTitle)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - 单行

    private func row(index: Int, tab: Tab) -> some View {
        let group = tabGroupStore.group(for: tab.id)
        return HStack(spacing: 8) {
            if let color = tabGroupColor(tab.id) {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            faviconPlaceholder(tab)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: index == selectedIndex ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if tab.audioMuted || tab.isPlayingAudio {
                    HStack(spacing: 3) {
                        Image(systemName: tab.audioMuted ? "speaker.slash.fill" : "waveform")
                            .font(.system(size: 8))
                        Text(tab.audioMuted ? "已静音" : "播放中")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if index == selectedIndex {
                Circle().fill(appAccent).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelectTab(index) }
        .contextMenu {
            Button("Reload") { onReloadTab(tab) }
            Button("Copy URL") { onCopyTabURL(tab) }
            Button(tab.audioMuted ? "Unmute Tab" : "Mute Tab") { onToggleAudioMute(index) }
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { onTogglePin(index) }
            Divider()
            Button("Close Tab") { onCloseTab(index) }
            Button("Close Other Tabs") { onCloseOtherTabs(index) }
            Button("Close Tabs to the Right") { onCloseTabsToRight(index) }
            Divider()
            // 组操作与顶部栏胶囊一致（v0.7.18）：组名进菜单标题，改名/折叠/
            // 删组/移出组齐备；未入组的提供"加入组"。
            if let group {
                Menu("Group: \(group.name)") {
                    if group.isCollapsed {
                        Button("Open Group") { onToggleGroupCollapse(group.id) }
                    } else {
                        Button("Collapse Group") { onToggleGroupCollapse(group.id) }
                    }
                    Button("Rename Group…") {
                        TabGroupPrompts.presentRename(group: group) { newName in
                            onRenameGroup(group.id, newName)
                        }
                    }
                    Button("Delete Group") { onDeleteGroup(group.id) }
                    Divider()
                    Button("Remove from Group") { onRemoveFromGroup(tab.id) }
                }
            } else {
                // 与顶栏一致：菜单常驻——没有组时仍有"新建分组…"可走
                // （此前 `!tabGroups.isEmpty` 门把无组场景的整体入口吞掉）。
                Menu("Add to Group") {
                    ForEach(tabGroups) { g in
                        Button(g.name) { onAddToGroup(tab.id, g.id) }
                    }
                    if !tabGroups.isEmpty { Divider() }
                    Button("New Group…") { onCreateGroup(index) }
                }
            }
        }
    }

    @ViewBuilder
    private func faviconPlaceholder(_ tab: Tab) -> some View {
        Image(systemName: tab.isOnNewTabPage ? "plus.square.on.square" : "globe")
            .font(.system(size: 11))
            .foregroundStyle(indexColor(for: tab))
            .frame(width: 16)
    }

    private func indexColor(for tab: Tab) -> Color {
        indexSelected(tab) ? appAccent : .secondary
    }

    private func indexSelected(_ tab: Tab) -> Bool {
        tabManager.tabs.firstIndex(where: { $0.id == tab.id }) == selectedIndex
    }
}
