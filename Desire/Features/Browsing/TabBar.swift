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
    let onCloseOtherTabs: (Int) -> Void
    let onCloseTabsToRight: (Int) -> Void
    let onToggleAudioMute: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        tabPill(for: tab, at: index)
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
    }

    private func tabPill(for tab: Tab, at index: Int) -> some View {
        HStack(spacing: 6) {
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
            if tab.isLoading {
                ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
            } else if tab.isIncognito {
                Image(systemName: "mask").font(.caption)
            } else if tab.isOnNewTabPage {
                Image(systemName: "asterisk").font(.caption)
            } else {
                FaviconView(urlString: tab.browser.webView.url?.absoluteString ?? tab.urlString, size: 14)
            }
            Text(tab.displayTitle)
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: 120)
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

        Button("关闭标签页") { onCloseTab(index) }
            .disabled(tabs.count <= 1)
        Button("关闭其他标签页") { onCloseOtherTabs(index) }
            .disabled(tabs.count <= 1)
        Button("关闭右侧标签页") { onCloseTabsToRight(index) }
            .disabled(index >= tabs.count - 1)
    }

    private func tabSwitcher() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                HStack(spacing: 8) {
                    Circle()
                        .fill(tab.isLoading ? Color.accentColor : (tab.isOnNewTabPage ? Color.secondary.opacity(0.3) : .clear))
                        .frame(width: 6, height: 6)

                    if tab.isIncognito {
                        Image(systemName: "mask").font(.caption).foregroundStyle(.purple)
                    }
                    Text(tab.displayTitle)
                        .lineLimit(1)
                        .font(.system(size: 13))
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

            Divider()

            HStack(spacing: 12) {
                Button {
                    onAddTab()
                } label: {
                    Label("新标签页", systemImage: "plus")
                }
                .keyboardShortcut("t", modifiers: .command)

                Spacer()
            }
            .padding(8)
        }
        .frame(width: 280)
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
