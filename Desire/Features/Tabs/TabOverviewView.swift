import SwiftUI
import WebKit

/// 全窗口标签概览（0.2.19）：Safari ⇧⌘\ 式的缩略图网格——当前窗口的
/// 所有标签铺成卡片，点击切换、悬停可关、末尾 "+" 新建，Esc/点击背景
/// 退出。缩略图由 TabThumbnailStore 提供（卡片出现时惰性捕获）。
struct TabOverviewView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var thumbnailStore: TabThumbnailStore
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    let onAddTab: () -> Void
    let onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 36)]

    var body: some View {
        ZStack {
            // 暗色背景：点背景 = 退出概览。
            Color.black.opacity(0.62)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        overviewCard(index: index, tab: tab)
                    }
                    newTabTile
                }
                .padding(.horizontal, 64)
                .padding(.vertical, 72)
            }
        }
        .onExitCommand { onClose() } // Esc
    }

    // MARK: - Card

    @ViewBuilder
    private func overviewCard(index: Int, tab: Tab) -> some View {
        let isSelected = index == tabManager.selectedIndex
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                thumbnailArea(tab)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // 悬停显示关闭按钮。
                Button {
                    onCloseTab(index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .opacity(hoverStates[tab.id] == true ? 1 : 0)
                .help("Close Tab")
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.12),
                            lineWidth: isSelected ? 2.5 : 1)
            )

            HStack(spacing: 6) {
                FaviconView(urlString: tab.browser.webView.url?.absoluteString ?? tab.urlString, size: 14)
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white.opacity(0.85)))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectTab(index)
            onClose()
        }
        .onHover { hovering in
            hoverStates[tab.id] = hovering
        }
        .onAppear {
            // 缩略图缺失（或已过期）→ 惰性捕获；懒加载网格保证只截
            // 可见卡片。
            if thumbnailStore.thumbnail(for: tab.id) == nil {
                thumbnailStore.captureThumbnail(for: tab)
            }
        }
    }

    @State private var hoverStates: [UUID: Bool] = [:]

    @ViewBuilder
    private func thumbnailArea(_ tab: Tab) -> some View {
        if let image = thumbnailStore.thumbnail(for: tab.id) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            // 无缩略图（新标签/加载中/未捕获）：渐变占位 + 标题。
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.22), Color.secondary.opacity(0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                VStack(spacing: 8) {
                    Image(systemName: tab.isOnNewTabPage ? "plus.square.dashed" : "globe")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(tab.displayTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private var newTabTile: some View {
        Button {
            onAddTab()
            onClose()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                Image(systemName: "plus")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(height: 190)
        }
        .buttonStyle(.plain)
        .help("New Tab")
    }
}
