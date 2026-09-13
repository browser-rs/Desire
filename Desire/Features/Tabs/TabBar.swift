import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct TabBar: View {
    let tabs: [Tab]
    let selectedIndex: Int
    let isFullScreen: Bool
    let showSwitcher: Bool
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    let onAddTab: () -> Void
    /// Registered containers — shown in the "+" button's right-click menu.
    var containers: [TabContainer] = []
    /// Opens a new tab inside `container` (right-click on "+").
    var onAddTabInContainer: ((TabContainer) -> Void)? = nil
    let onMoveTab: (Int, Int) -> Void
    let onReloadTab: (Tab) -> Void
    let onCopyTabURL: (Tab) -> Void
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    let onCloseOtherTabs: (Int) -> Void
    let onCloseTabsToRight: (Int) -> Void
    let onToggleAudioMute: (Int) -> Void
    let onTogglePin: (Int) -> Void
    /// Derived from TabGroupStore: group color for a tab (nil if ungrouped).
    let tabGroupColor: (UUID) -> Color?
    /// Available tab groups (for context menus).
    let tabGroups: [TabGroup]
    let onRemoveFromGroup: (UUID) -> Void
    let onAddToGroup: (UUID, UUID) -> Void
    /// Derived from TabThumbnailStore: thumbnail image for a tab.
    let tabThumbnail: (UUID) -> NSImage?
    let onCaptureThumbnail: (Tab) -> Void
    let onCreateGroup: (Int) -> Void
    let onDuplicateTab: (Int) -> Void
    
    // Preview state - preview shown via separate NSPanel
    @State private var previewTabId: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    let pinned = tabs.filter(\.isPinned)
                    let regular = tabs.filter { !$0.isPinned }
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { index, tab in
                        if let realIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
                            TabPillView(
                                tab: tab,
                                index: realIndex,
                                selectedIndex: selectedIndex,
                                actions: TabBar.TabPillActions(
                                    selectTab: onSelectTab,
                                    closeTab: onCloseTab,
                                    reloadTab: onReloadTab,
                                    copyTabURL: onCopyTabURL,
                                    toggleAudioMute: onToggleAudioMute,
                                    togglePin: onTogglePin,
                                    closeOtherTabs: onCloseOtherTabs,
                                    closeTabsToRight: onCloseTabsToRight,
                                    addTab: onAddTab,
                                    createGroup: onCreateGroup,
                                    duplicateTab: onDuplicateTab
                                ),
                                tabs: tabs,
                                groupColor: tabGroupColor(tab.id),
                                tabGroups: tabGroups,
                                onRemoveFromGroup: onRemoveFromGroup,
                                onAddToGroup: onAddToGroup,
                                onCaptureThumbnail: onCaptureThumbnail,
                                onMoveTab: onMoveTab,
                                onShowPreview: { tab, frame in
                                    previewTabId = tab.id
                                    let nsWindow = NSApp.keyWindow ?? NSApp.mainWindow
                                    TabPreviewPanel.shared.show(
                                        tab: tab,
                                        thumbnail: tabThumbnail(tab.id),
                                        anchor: frame,
                                        in: nsWindow
                                    )
                                },
                                onUpdatePreview: { tab in
                                    TabPreviewPanel.shared.updateThumbnail(
                                        tabThumbnail(tab.id),
                                        for: tab
                                    )
                                },
                                onHidePreview: {
                                    previewTabId = nil
                                    TabPreviewPanel.shared.hide()
                                }
                            )
                                .frame(width: 50)
                        }
                    }
                    if !pinned.isEmpty && !regular.isEmpty {
                        Divider().frame(height: 18)
                    }
                    ForEach(Array(regular.enumerated()), id: \.element.id) { index, tab in
                        if let realIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
                            TabPillView(
                                tab: tab,
                                index: realIndex,
                                selectedIndex: selectedIndex,
                                actions: TabBar.TabPillActions(
                                    selectTab: onSelectTab,
                                    closeTab: onCloseTab,
                                    reloadTab: onReloadTab,
                                    copyTabURL: onCopyTabURL,
                                    toggleAudioMute: onToggleAudioMute,
                                    togglePin: onTogglePin,
                                    closeOtherTabs: onCloseOtherTabs,
                                    closeTabsToRight: onCloseTabsToRight,
                                    addTab: onAddTab,
                                    createGroup: onCreateGroup,
                                    duplicateTab: onDuplicateTab
                                ),
                                tabs: tabs,
                                groupColor: tabGroupColor(tab.id),
                                tabGroups: tabGroups,
                                onRemoveFromGroup: onRemoveFromGroup,
                                onAddToGroup: onAddToGroup,
                                onCaptureThumbnail: onCaptureThumbnail,
                                onMoveTab: onMoveTab,
                                onShowPreview: { tab, frame in
                                    previewTabId = tab.id
                                    let nsWindow = NSApp.keyWindow ?? NSApp.mainWindow
                                    TabPreviewPanel.shared.show(
                                        tab: tab,
                                        thumbnail: tabThumbnail(tab.id),
                                        anchor: frame,
                                        in: nsWindow
                                    )
                                },
                                onUpdatePreview: { tab in
                                    TabPreviewPanel.shared.updateThumbnail(
                                        tabThumbnail(tab.id),
                                        for: tab
                                    )
                                },
                                onHidePreview: {
                                    previewTabId = nil
                                    TabPreviewPanel.shared.hide()
                                }
                            )
                        }
                    }
                }
            }

            Button {
                onAddTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab")
            .contextMenu {
                if containers.isEmpty {
                    Text("No containers — create one in Settings > Tabs")
                } else {
                    Section("New Container Tab") {
                        ForEach(containers) { container in
                            Button {
                                onAddTabInContainer?(container)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(container.color).frame(width: 8, height: 8)
                                    Text(container.name)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, isFullScreen ? 12 : 76)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .background(Color.clear)
        .overlay(alignment: .topLeading) {
            if showSwitcher {
                TabPopoverView(
                    tabs: tabs,
                    selectedIndex: selectedIndex,
                    onSelectTab: onSelectTab,
                    onAddTab: onAddTab,
                    searchText: $searchText,
                    isSearchFocused: $isSearchFocused
                )
            }
        }
        .onChange(of: showSwitcher) { _, shown in
            if shown {
                searchText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isSearchFocused = true
                }
            }
        }
        .onDisappear {
            TabPreviewPanel.shared.hide()
        }
    }

    // MARK: - Tab pill actions

    struct TabPillActions {
        let selectTab: (Int) -> Void
        let closeTab: (Int) -> Void
        let reloadTab: (Tab) -> Void
        let copyTabURL: (Tab) -> Void
        let toggleAudioMute: (Int) -> Void
        let togglePin: (Int) -> Void
        let closeOtherTabs: (Int) -> Void
        let closeTabsToRight: (Int) -> Void
        let addTab: () -> Void
        let createGroup: (Int) -> Void
        let duplicateTab: (Int) -> Void
    }
}

private struct TabPillView: View {
    @ObservedObject var tab: Tab
    let index: Int
    let selectedIndex: Int
    let actions: TabBar.TabPillActions
    let tabs: [Tab]
    /// Derived from TabGroupStore: the color for this tab's group, if any.
    let groupColor: Color?
    /// Available tab groups for the context menu.
    let tabGroups: [TabGroup]
    let onRemoveFromGroup: (UUID) -> Void
    let onAddToGroup: (UUID, UUID) -> Void
    /// Derived from TabThumbnailStore: captures a thumbnail for `tab`.
    let onCaptureThumbnail: (Tab) -> Void
    let onMoveTab: (Int, Int) -> Void
    let onShowPreview: (Tab, CGRect) -> Void
    let onUpdatePreview: (Tab) -> Void
    let onHidePreview: () -> Void
    
    @State private var isHovering = false
    @State private var hoverTimer: Timer?
    @State private var pillFrame: CGRect = .zero

    var body: some View {
        let showClose = !tab.isPinned && isHovering
        HStack(spacing: 6) {
            if let gc = groupColor {
                Capsule()
                    .fill(gc)
                    .frame(width: 3, height: 14)
            }
            if tab.isIncognito {
                Image(systemName: "mask").font(.caption)
            } else if tab.isOnNewTabPage {
                Image(systemName: "asterisk").font(.caption)
            } else {
                FaviconView(urlString: tab.browser.webView.url?.absoluteString ?? tab.urlString, size: 14)
                    .overlay(alignment: .bottomTrailing) {
                        if tab.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.secondary)
                                .offset(x: 4, y: 4)
                        }
                    }
            }
            if tab.isPlayingAudio {
                Button {
                    tab.audioMuted.toggle()
                } label: {
                    Image(systemName: tab.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(tab.audioMuted ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(tab.audioMuted ? "Unmute tab" : "Mute tab")
            }
            if !tab.isPinned {
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: 120)
            }
            Button(action: { actions.closeTab(index) }) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(showClose ? 1 : 0)
            .allowsHitTesting(showClose)
            .animation(.hoverFast, value: showClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            Capsule()
                .fill(index == selectedIndex
                      ? Color(nsColor: .controlBackgroundColor)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            Capsule()
                .stroke(index == selectedIndex
                        ? Color.accentColor
                        : Color.secondary.opacity(0.25),
                        lineWidth: index == selectedIndex ? 1.5 : 0.5)
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { pillFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, new in
                        pillFrame = new
                    }
            }
        )
        .onHover { hovering in
            isHovering = hovering
            if hovering && !tab.isOnNewTabPage {
                // Delay showing preview (1 second)
                hoverTimer?.invalidate()
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                    Task { @MainActor in
                        onShowPreview(tab, pillFrame)
                        // Capture thumbnail on hover
                        onCaptureThumbnail(tab)
                        onUpdatePreview(tab)
                    }
                }
            } else {
                hoverTimer?.invalidate()
                onHidePreview()
            }
        }
        .onTapGesture {
            hoverTimer?.invalidate()
            onHidePreview()
            actions.selectTab(index)
        }
        .onDrag {
            hoverTimer?.invalidate()
            onHidePreview()
            let provider = NSItemProvider(object: NSString(string: "\(index)"))
            return provider
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(targetIndex: index, onMoveTab: onMoveTab))
        .contextMenu { tabContextMenu }
    }

    @ViewBuilder
    private var tabContextMenu: some View {
        Button("New Tab") { actions.addTab() }
        Button("Duplicate Tab") { actions.duplicateTab(index) }
        Button("Reload") { actions.reloadTab(tab) }
            .disabled(tab.isOnNewTabPage)
        Button("Copy URL") { actions.copyTabURL(tab) }
            .disabled(tab.isOnNewTabPage)

        Divider()

        if let group = tabGroups.first(where: { $0.tabIds.contains(tab.id) }) {
            Menu("Group: \(group.name)") {
                Button("Remove from Group") { onRemoveFromGroup(tab.id) }
            }
        } else {
            Menu("Add to Group") {
                ForEach(tabGroups) { group in
                    Button(group.name) { onAddToGroup(tab.id, group.id) }
                }
                if !tabGroups.isEmpty { Divider() }
                Button("New Group…") { actions.createGroup(index) }
            }
        }

        Button(tab.isPinned ? "Unpin" : "Pin Tab") { actions.togglePin(index) }
        Divider()

        Button("Close Tab") { actions.closeTab(index) }
            .disabled(tabs.count <= 1)
        Button("Close Other Tabs") { actions.closeOtherTabs(index) }
            .disabled(tabs.count <= 1)
        Button("Close Tabs to Right") { actions.closeTabsToRight(index) }
            .disabled(index >= tabs.count - 1)
    }
}

private struct TabPopoverView: View {
    let tabs: [Tab]
    let selectedIndex: Int
    let onSelectTab: (Int) -> Void
    let onAddTab: () -> Void
    @Binding var searchText: String
    var isSearchFocused: FocusState<Bool>.Binding

    private var filtered: [(offset: Int, element: Tab)] {
        if searchText.isEmpty {
            return Array(tabs.enumerated())
        }
        let q = searchText.lowercased()
        return tabs.enumerated().filter { _, t in
            t.displayTitle.lowercased().contains(q) ||
            t.urlString.lowercased().contains(q) ||
            (t.browser.webView.url?.absoluteString.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search Tabs…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(isSearchFocused)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.element.id) { index, tab in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(tab.isLoading ? Color.accentColor : (tab.isOnNewTabPage ? Color.secondary.opacity(0.3) : .clear))
                                .frame(width: 6, height: 6)

                            if tab.isIncognito {
                                Image(systemName: "mask").font(.caption).foregroundStyle(.purple)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.displayTitle)
                                    .lineLimit(1)
                                    .font(.system(size: 13))
                                if !tab.isOnNewTabPage {
                                    Text(tab.browser.webView.url?.absoluteString ?? tab.urlString)
                                        .lineLimit(1)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if index == selectedIndex {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(index == selectedIndex ? Color.accentColor.opacity(0.1) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectTab(index)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            HStack(spacing: 12) {
                Button {
                    onAddTab()
                } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))

                Spacer()

                Text("\(filtered.count) / \(tabs.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: .radiusPopover)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadowProminent()
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusPopover)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

private struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let onMoveTab: (Int, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let str = reading as? String, let source = Int(str) else { return }
            Task { @MainActor in
                onMoveTab(source, targetIndex)
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // 提供视觉反馈，显示拖拽目标位置
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // 拖拽退出时的处理（可用于视觉反馈）
    }
}

/// 拖拽到新窗口的检测和处理器
private class TabDragToNewWindowHandler: ObservableObject {
    @Published var isDraggingToNewWindow = false
    private var dragStartLocation: CGPoint = .zero
    private let thresholdDistance: CGFloat = 100 // 拖拽距离阈值

    func startDrag(at location: CGPoint) {
        dragStartLocation = location
        isDraggingToNewWindow = false
    }

    func updateDrag(at location: CGPoint, windowBounds: CGRect) {
        // 检测是否拖拽到窗口外
        let distance = hypot(location.x - dragStartLocation.x, location.y - dragStartLocation.y)
        let isOutsideWindow = !windowBounds.contains(location)

        if distance > thresholdDistance && isOutsideWindow {
            isDraggingToNewWindow = true
        }
    }

    func endDrag() {
        dragStartLocation = .zero
        isDraggingToNewWindow = false
    }
}

