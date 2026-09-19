import SwiftUI
import WebKit

/// 全窗口标签概览（0.2.19）：Safari ⇧⌘\ 式。瓦片不是截图——直接挂载
/// 每个标签**存活的 WKWebView 本体**（固定基准尺寸 + scaleEffect 缩小，
/// 页面不重排，即迷你窗口效果），点击瓦片切换、悬停可关、末尾 "+"
/// 新建。概览打开期间主内容区给选中标签让位（同一 NSView 不能双宿主，
/// 见 SelectedTabContent 的占位分支）。
struct TabOverviewView: View {
    @ObservedObject var tabManager: TabManager
    /// 与 SelectedTabContent 同款：引用 ContentView 以复用 makeWebView。
    let content: ContentView
    let onSelectTab: (Int) -> Void
    let onCloseTab: (Int) -> Void
    let onAddTab: () -> Void
    let onClose: () -> Void

    /// 瓦片内 webview 的基准布局尺寸（页面按此宽度渲染，再整体缩小）。
    private static let baseSize = CGSize(width: 1280, height: 800)
    private static let columns = 3

    var body: some View {
        GeometryReader { geo in
            let cellW = max(280, (geo.size.width - 2 * 56 - CGFloat(Self.columns - 1) * 40) / CGFloat(Self.columns))
            let scale = cellW / Self.baseSize.width
            let cellH = Self.baseSize.height * scale

            ScrollView {
                // 分级渲染（0.3.4）：LazyVGrid 只挂载可见行的活 webview；
                // 滚出屏幕的瓦片自动摘除（WKWebView 对象由 Tab 持有，
                // 摘除不销毁页面，滚回时重新挂载）。50 标签概览的常驻
                // 活视图从 50 → 一屏 ≤9。
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellW), spacing: 40), count: Self.columns),
                          spacing: 44) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        overviewCard(index: index, tab: tab,
                                     width: cellW, height: cellH, scale: scale)
                    }
                    newTabTile(width: cellW, height: cellH)
                }
                .padding(.horizontal, 56)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(red: 0.13, green: 0.16, blue: 0.21).onTapGesture { onClose() })
        .onExitCommand { onClose() } // Esc
    }

    // MARK: - Card

    @State private var hoverStates: [UUID: Bool] = [:]

    @ViewBuilder
    private func overviewCard(index: Int, tab: Tab, width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        let isSelected = index == tabManager.selectedIndex
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // 活的 webview 本体：基准尺寸渲染 + 缩小（不重排）。
                // 禁点击——瓦片点击语义是"切换标签"，不是操作页面。
                tileContent(tab)
                    .frame(width: Self.baseSize.width, height: Self.baseSize.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .allowsHitTesting(false)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .clipped()

                // 顶部条：✕ 居左，favicon + 标题居中（Safari 布局）。
                HStack(spacing: 8) {
                    Button {
                        onCloseTab(index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .opacity(hoverStates[tab.id] == true ? 1 : 0)
                    .help("Close Tab")

                    Spacer(minLength: 0)

                    HStack(spacing: 5) {
                        FaviconView(urlString: tab.browser.webView.url?.absoluteString ?? tab.urlString, size: 12)
                        Text(tab.displayTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Color.clear.frame(width: 18, height: 18) // 平衡左侧，标题居中
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
            .frame(height: height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.14),
                            lineWidth: isSelected ? 3 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectTab(index)
                onClose()
            }
            .onHover { hovering in hoverStates[tab.id] = hovering }
        }
    }

    /// 瓦片内容：非新标签页挂活 webview；新标签/挂起页给占位（它们的
    /// webview 是空白的，展示无意义）。
    @ViewBuilder
    private func tileContent(_ tab: Tab) -> some View {
        if tab.isOnNewTabPage || tab.isSuspended {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.20), Color.secondary.opacity(0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                VStack(spacing: 10) {
                    Image(systemName: tab.isOnNewTabPage ? "plus.square.dashed" : "moon.zzz")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(tab.displayTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        } else {
            content.makeWebView(for: tab)
        }
    }

    private func newTabTile(width: CGFloat, height: CGFloat) -> some View {
        Button {
            onAddTab()
            onClose()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .help("New Tab")
    }
}
