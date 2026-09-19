import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct TabBar: View {
    let tabs: [Tab]
    let selectedIndex: Int
    let isFullScreen: Bool
    @Binding var showSwitcher: Bool
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    /// Closes by tab identity, resolving the index live at call time. Used
    /// by middle-click close, whose registered closure would otherwise hold
    /// a stale index/tab-count snapshot (pill frames don't change when other
    /// tabs are added/removed, so no re-registration fires).
    let onCloseTabID: (UUID) -> Void
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
    /// Resolves a tab's container (nil for default-store tabs) for badge display.
    let containerFor: (UUID?) -> TabContainer?
    /// Expands/collapses a tab group (collapsed groups render as one pill).
    let onToggleGroupCollapse: (UUID) -> Void
    /// Deletes a group (its tabs survive, ungrouped).
    let onDeleteGroup: (UUID) -> Void
    /// Available tab groups (for context menus).
    let tabGroups: [TabGroup]
    let onRemoveFromGroup: (UUID) -> Void
    let onAddToGroup: (UUID, UUID) -> Void
    /// 本窗口会话 ID（拖拽 provider 的来源标识）。
    let windowSessionID: String
    /// Derived from TabThumbnailStore: thumbnail image for a tab.
    let tabThumbnail: (UUID) -> NSImage?
    let onCaptureThumbnail: (Tab) -> Void
    let onCreateGroup: (Int) -> Void
    let onDuplicateTab: (Int) -> Void
    /// 分屏浏览（0.2.15）：右栏标签的下标（nil = 未分屏）+ 切换动作。
    var splitPartnerIndex: Int? = nil
    var onToggleSplit: ((Int) -> Void)? = nil
    /// 全窗口标签概览（0.2.19，Safari ⇧⌘\ 式网格）：开/关 toggle。
    var isTabOverviewActive: Bool = false
    var onToggleTabOverview: (() -> Void)? = nil
    /// 拖动开始（用于拖出监视：拖出窗口边界 → 撕出为新窗口）。
    let onDragStarted: (Tab) -> Void
    /// 跨窗口拖入：把别的窗口拖来的标签并入本条。（条级落点/条上落点）
    let onTransferIn: (UUID, UUID, Int?) -> Void
    
    // Preview state - preview shown via separate NSPanel
    @State private var previewTabId: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    let pinned = tabs.filter(\.isPinned)
                    // Collapsed groups hide their tabs and render as one pill.
                    let collapsedGroups = tabGroups
                        .filter { $0.isCollapsed }
                        .compactMap { group -> TabGroup? in
                            tabs.contains(where: { group.tabIds.contains($0.id) }) ? group : nil
                        }
                    let collapsedTabIDs = Set(collapsedGroups.flatMap { $0.tabIds })
                    let regular = tabs.filter { !$0.isPinned && !collapsedTabIDs.contains($0.id) }

                    ForEach(collapsedGroups) { group in
                        Button {
                            onToggleGroupCollapse(group.id)
                        } label: {
                            HStack(spacing: 5) {
                                if let color = tabGroupColor(group.tabIds.first ?? UUID()) {
                                    Circle().fill(color).frame(width: 7, height: 7)
                                }
                                Text(group.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Text("\(group.tabIds.count)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                Capsule().stroke(
                                    tabGroupColor(group.tabIds.first ?? UUID()) ?? Color.secondary.opacity(0.3),
                                    lineWidth: 1
                                )
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open Group")
                        .contextMenu {
                            Button("Open Group") { onToggleGroupCollapse(group.id) }
                            Button("Delete Group") { onDeleteGroup(group.id) }
                        }
                    }
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { index, tab in
                        if let realIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
                            TabPillView(
                                tab: tab,
                                index: realIndex,
                                selectedIndex: selectedIndex,
                                splitPartnerIndex: splitPartnerIndex,
                                windowSessionID: windowSessionID,
                                onDragStarted: onDragStarted,
                                onTransferIn: onTransferIn,
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
                                    duplicateTab: onDuplicateTab,
                                    toggleSplit: onToggleSplit ?? { _ in }
                                ),
                                onCloseTabID: onCloseTabID,
                                tabs: tabs,
                                groupColor: tabGroupColor(tab.id),
                                containerColor: containerFor(tab.containerID)?.color,
                                onToggleGroupCollapse: onToggleGroupCollapse,
                                onDeleteGroup: onDeleteGroup,
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
                                splitPartnerIndex: splitPartnerIndex,
                                windowSessionID: windowSessionID,
                                onDragStarted: onDragStarted,
                                onTransferIn: onTransferIn,
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
                                    duplicateTab: onDuplicateTab,
                                    toggleSplit: onToggleSplit ?? { _ in }
                                ),
                                onCloseTabID: onCloseTabID,
                                tabs: tabs,
                                groupColor: tabGroupColor(tab.id),
                                containerColor: containerFor(tab.containerID)?.color,
                                onToggleGroupCollapse: onToggleGroupCollapse,
                                onDeleteGroup: onDeleteGroup,
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

            Button {
                onToggleTabOverview?()
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isTabOverviewActive ? Color.accentColor : .primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isTabOverviewActive ? "Close Tab Overview (⇧⌘\\)" : "Tab Overview (⇧⌘\\)")
        }
        .padding(.leading, isFullScreen ? 12 : 76)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .background(Color.clear)
        .popover(isPresented: $showSwitcher, arrowEdge: .bottom) {
            TabPopoverView(
                tabs: tabs,
                selectedIndex: selectedIndex,
                onSelectTab: onSelectTab,
                onAddTab: onAddTab,
                searchText: $searchText,
                isSearchFocused: $isSearchFocused,
                onClose: { showSwitcher = false }
            )
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
        /// 分屏浏览（0.2.15）：把该标签设为/移出分屏右栏。
        let toggleSplit: (Int) -> Void
    }
}

private struct TabPillView: View {
    @ObservedObject var tab: Tab
    let index: Int
    let selectedIndex: Int
    /// 分屏右栏的下标（nil = 未分屏）——右栏胶囊用弱高亮区分。
    let splitPartnerIndex: Int?
    let windowSessionID: String
    let onDragStarted: (Tab) -> Void
    /// 跨窗口拖入的落点回调（透传给条级落点代理）。
    let onTransferIn: ((UUID, UUID, Int?) -> Void)?
    let actions: TabBar.TabPillActions
    /// Live close-by-identity channel for the middle-click monitor.
    let onCloseTabID: (UUID) -> Void
    let tabs: [Tab]
    /// Derived from TabGroupStore: the color for this tab's group, if any.
    let groupColor: Color?
    /// Container badge color, if this tab belongs to a container.
    let containerColor: Color?
    let onToggleGroupCollapse: (UUID) -> Void
    let onDeleteGroup: (UUID) -> Void
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

    /// Publishes this pill's frame + close action to the middle-click
    /// monitor. The closure captures ONLY the tab id — the index and tab
    /// list are resolved live by the receiver, so a frame registered before
    /// other tabs were added/removed still closes the right tab.
    private func registerMiddleClickFrame() {
        let tabID = tab.id
        TabMiddleClickMonitor.shared.register(
            frame: pillFrame,
            for: tabID,
            close: { onCloseTabID(tabID) }
        )
    }

    var body: some View {
        let showClose = !tab.isPinned && isHovering
        HStack(spacing: 6) {
            if let gc = groupColor {
                Capsule()
                    .fill(gc)
                    .frame(width: 3, height: 14)
            }
            if let cc = containerColor {
                Circle()
                    .fill(cc)
                    .frame(width: 7, height: 7)
                    .help("Container tab")
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
            .scaleEffect(showClose ? 1 : 0.6)
            .allowsHitTesting(showClose)
            .animation(.controlSpring, value: showClose)
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
            Capsule().stroke(
                index == selectedIndex
                    ? Color.accentColor
                    : index == splitPartnerIndex
                        ? Color.accentColor.opacity(0.45)
                        : Color.secondary.opacity(0.25),
                lineWidth: index == selectedIndex ? 1.5 : 1
            )
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        pillFrame = geo.frame(in: .global)
                        registerMiddleClickFrame()
                    }
                    .onChange(of: geo.frame(in: .global)) { _, new in
                        pillFrame = new
                        registerMiddleClickFrame()
                    }
            }
        )
        .onDisappear {
            TabMiddleClickMonitor.shared.unregister(id: tab.id)
        }
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
            onDragStarted(tab)
            return NSItemProvider(object: NSString(string: "\(windowSessionID)|\(tab.id.uuidString)|\(index)"))
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetIndex: index,
            ownSessionID: windowSessionID,
            onMoveTab: onMoveTab,
            onTransferIn: onTransferIn
        ))
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
        Button(index == splitPartnerIndex ? "Remove from Split" : "Show Alongside (Split)") {
            actions.toggleSplit(index)
        }
        .disabled(index == selectedIndex)

        Divider()

        if let group = tabGroups.first(where: { $0.tabIds.contains(tab.id) }) {
            Menu("Group: \(group.name)") {
                if group.isCollapsed {
                    Button("Open Group") { onToggleGroupCollapse(group.id) }
                } else {
                    Button("Collapse Group") { onToggleGroupCollapse(group.id) }
                }
                Button("Delete Group") { onDeleteGroup(group.id) }
                Divider()
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
    let onClose: () -> Void

    /// 键盘导航（↑/↓ 移动、Enter 选中、Esc 关闭）：本地事件监视器，
    /// 优先于搜索框的 field editor 消费方向键。
    @State private var keyboardRow: Int?
    @State private var keyMonitor: Any?

    private var activeRow: Int? {
        keyboardRow ?? filtered.firstIndex(where: { $0.offset == selectedIndex })
    }

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
                        .background(hotRowBackground(index))
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
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            keyboardRow = nil
        }
    }

    private func hotRowBackground(_ index: Int) -> Color {
        let active = activeRow ?? selectedIndex
        return index == active ? Color.accentColor.opacity(0.1) : .clear
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let rows = filtered
            guard !rows.isEmpty else { return event }
            switch event.keyCode {
            case 125: // down
                keyboardRow = min((activeRow ?? -1) + 1, rows.count - 1)
                return nil
            case 126: // up
                keyboardRow = max((activeRow ?? 1) - 1, 0)
                return nil
            case 36: // return
                if let row = activeRow, rows.indices.contains(row) {
                    onSelectTab(rows[row].offset)
                    onClose()
                }
                return nil
            case 53: // esc
                onClose()
                return nil
            default:
                return event
            }
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let ownSessionID: String
    let onMoveTab: (Int, Int) -> Void
    /// 跨窗口拖入：(来源窗口会话, 标签 UUID, 落点 index)。
    let onTransferIn: ((UUID, UUID, Int?) -> Void)?

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let str = reading as? String else { return }
            Task { @MainActor in
                // 新格式 "originSession|tabID|index"；旧格式纯数字 = 本窗排序。
                let parts = str.split(separator: "|").map(String.init)
                if parts.count == 3,
                   let origin = UUID(uuidString: parts[0]),
                   let tabID = UUID(uuidString: parts[1]),
                   let sourceIndex = Int(parts[2]) {
                    if parts[0].lowercased() == ownSessionID.lowercased() {
                        onMoveTab(sourceIndex, targetIndex)
                    } else {
                        onTransferIn?(origin, tabID, targetIndex)
                    }
                    return
                }
                if let source = Int(str) {
                    onMoveTab(source, targetIndex)
                }
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

