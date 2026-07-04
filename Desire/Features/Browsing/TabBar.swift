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
    let onMoveTab: (Int, Int) -> Void
    let onReloadTab: (Tab) -> Void
    let onCopyTabURL: (Tab) -> Void
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    let onCloseOtherTabs: (Int) -> Void
    let onCloseTabsToRight: (Int) -> Void
    let onToggleAudioMute: (Int) -> Void
    let onTogglePin: (Int) -> Void
    @ObservedObject var tabGroupStore: TabGroupStore
    let onCreateGroup: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    let pinned = tabs.filter(\.isPinned)
                    let regular = tabs.filter { !$0.isPinned }
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { index, tab in
                        if let realIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
                            tabPill(for: tab, at: realIndex)
                                .frame(width: 50)
                        }
                    }
                    if !pinned.isEmpty && !regular.isEmpty {
                        Divider().frame(height: 18)
                    }
                    ForEach(Array(regular.enumerated()), id: \.element.id) { index, tab in
                        if let realIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
                            tabPill(for: tab, at: realIndex)
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
            .help("新标签页")
        }
        .padding(.leading, isFullScreen ? 12 : 76)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .background(Color.clear)
        .overlay(alignment: .topLeading) {
            if showSwitcher { tabSwitcher() }
        }
        .onChange(of: showSwitcher) { _, shown in
            if shown {
                searchText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isSearchFocused = true
                }
            }
        }
    }

    private func tabPill(for tab: Tab, at index: Int) -> some View {
        let groupColor = tabGroupStore.group(for: tab.id).map { tabGroupColors[$0.colorIndex % tabGroupColors.count] }

        return HStack(spacing: 6) {
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
            if tab.browser.isPlayingAudio {
                Button {
                    onToggleAudioMute(index)
                } label: {
                    Image(systemName: tab.browser.isMuted ? "speaker.slash" : "speaker.wave.2")
                        .font(.caption2)
                        .foregroundStyle(tab.browser.isMuted ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            if !tab.isPinned {
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: 120)
            }
            Button(action: { onCloseTab(index) }) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
        .contentShape(Capsule())
        .onTapGesture {
            onSelectTab(index)
        }
        .onDrag {
            let provider = NSItemProvider(object: NSString(string: "\(index)"))
            return provider
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(targetIndex: index, onMoveTab: onMoveTab))
        .contextMenu {
            tabContextMenu(for: tab, at: index)
        }
    }

    @ViewBuilder
    private func tabContextMenu(for tab: Tab, at index: Int) -> some View {
        Button("新建标签页") { onAddTab() }
        Button("重新加载") { onReloadTab(tab) }
            .disabled(tab.isOnNewTabPage)
        Button("复制网址") { onCopyTabURL(tab) }
            .disabled(tab.isOnNewTabPage)

        Divider()

        if let group = tabGroupStore.group(for: tab.id) {
            Menu("分组: \(group.name)") {
                Button("从分组移除") { tabGroupStore.removeTabFromAll(tab.id) }
            }
        } else {
            Menu("添加到分组") {
                ForEach(tabGroupStore.groups) { group in
                    Button(group.name) { tabGroupStore.addTab(tab.id, to: group.id) }
                }
                if !tabGroupStore.groups.isEmpty { Divider() }
                Button("新建分组…") { onCreateGroup(index) }
            }
        }

        Button(tab.isPinned ? "取消固定" : "固定标签页") { onTogglePin(index) }
        Divider()

        Button("关闭标签页") { onCloseTab(index) }
            .disabled(tabs.count <= 1)
        Button("关闭其他标签页") { onCloseOtherTabs(index) }
            .disabled(tabs.count <= 1)
        Button("关闭右侧标签页") { onCloseTabsToRight(index) }
            .disabled(index >= tabs.count - 1)
    }

    private func tabSwitcher() -> some View {
        let filtered: [(offset: Int, element: Tab)]
        if searchText.isEmpty {
            filtered = Array(tabs.enumerated())
        } else {
            let q = searchText.lowercased()
            filtered = tabs.enumerated().filter { _, t in
                t.displayTitle.lowercased().contains(q) ||
                t.urlString.lowercased().contains(q) ||
                (t.browser.webView.url?.absoluteString.lowercased().contains(q) ?? false)
            }
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("搜索标签页…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isSearchFocused)
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
                    Label("新标签页", systemImage: "plus")
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
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
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
}
