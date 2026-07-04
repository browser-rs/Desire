import AppKit
import SwiftUI
import WebKit

struct Toolbar: View {
    struct Actions {
        let goBack: () -> Void
        let goForward: () -> Void
        let reload: () -> Void
        let loadHome: () -> Void
        let navigate: (String) -> Void
        let toggleBookmark: () -> Void
        let toggleFullScreen: () -> Void
        let inspectElement: () -> Void
        let suggestionSelect: (AddressSuggestion) -> Void
        let printPage: () -> Void
        let zoomIn: () -> Void
        let zoomOut: () -> Void
        let resetZoom: () -> Void
    }

    let tab: Tab
    let settings: Settings
    @ObservedObject var suggestionModel: AddressSuggestionsModel
    let downloadStore: DownloadStore
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    let passwordStore: PasswordStore
    var isUrlFocused: FocusState<Bool>.Binding

    let actions: Actions

    @Binding var showHistory: Bool
    @Binding var showBookmarks: Bool
    @Binding var showUserScripts: Bool
    @Binding var showSettings: Bool

    @State private var showDownloads = false
    @State private var showPasswords = false
    @State private var showMoreMenu = false
    @State private var showSecurityInfo = false

    private var zoomPercent: String {
        let pct = Int((tab.browser.pageZoom * 100).rounded())
        return "\(pct)%"
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                BackForwardButton(direction: .back, webView: tab.browser.webView, canGo: tab.canGoBack, action: actions.goBack)
                BackForwardButton(direction: .forward, webView: tab.browser.webView, canGo: tab.canGoForward, action: actions.goForward)
                CapsuleButton(systemName: tab.isLoading ? "xmark" : "arrow.clockwise", action: {
                    if tab.isLoading { tab.browser.webView.stopLoading() } else { actions.reload() }
                }, help: tab.isLoading ? "停止" : "重新加载")
                CapsuleButton(systemName: "house", action: actions.loadHome, help: "主页")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 4) {
                Button {
                    showSecurityInfo.toggle()
                } label: {
                    Image(systemName: tab.browser.isSecure ? "lock.fill" : "lock.open")
                        .foregroundStyle(tab.browser.isSecure ? Color.secondary : Color.orange)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(tab.browser.isSecure ? "连接安全" : "连接不安全")
                .popover(isPresented: $showSecurityInfo) {
                    SecurityInfoView(trust: tab.browser.isSecure ? tab.browser.serverTrust : nil,
                                     host: tab.browser.webView.url?.host ?? "")
                }

                URLBarField(
                    text: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }),
                    isFocused: isUrlFocused,
                    onSubmit: { actions.navigate(tab.urlString) },
                    onPasteAndGo: {
                        if let str = NSPasteboard.general.string(forType: .string) {
                            tab.urlString = str
                            actions.navigate(str)
                        }
                    },
                    onMoveSelection: { delta in suggestionModel.moveSelection(by: delta) },
                    onEscape: {
                        suggestionModel.reset()
                        isUrlFocused.wrappedValue = false
                    },
                    onTextChange: { newValue in
                        suggestionModel.build(query: newValue, settings: settings, bookmarks: bookmarkStore, history: historyStore)
                    }
                )

                HoverIcon(systemName: isBookmarked ? "bookmark.fill" : "bookmark", action: actions.toggleBookmark, disabled: tab.isOnNewTabPage, help: isBookmarked ? "删除书签" : "添加书签")
                    .foregroundStyle(isBookmarked ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        Capsule().stroke(tab.isIncognito ? Color.purple.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
            .layoutPriority(1)

            Button {
                actions.resetZoom()
            } label: {
                Text(zoomPercent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
            .buttonStyle(.plain)
            .help("缩放比例 — 点击重置为 100%")

            HStack(spacing: 6) {
                DownloadButton(store: downloadStore, showDownloads: $showDownloads)

                Button {
                    showMoreMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showMoreMenu) {
                    VStack(spacing: 0) {
                        moreMenuItem("浏览历史", "clock.arrow.circlepath") { showHistory = true }
                        moreMenuItem("书签", "bookmark") { showBookmarks = true }
                        moreMenuItem("密码", "lock.keyhole") { showPasswords = true }
                        moreMenuItem("下载", "arrow.down.circle") { showDownloads = true }
                        moreMenuItem("用户脚本", "applescript") { showUserScripts = true }
                        moreMenuItem(isBookmarked ? "删除书签" : "添加书签", isBookmarked ? "bookmark.slash" : "bookmark.fill") { actions.toggleBookmark() }
                            .disabled(tab.isOnNewTabPage)
                        Divider()
                        moreMenuItem("放大", "plus.magnifyingglass") { actions.zoomIn() }
                        moreMenuItem("缩小", "minus.magnifyingglass") { actions.zoomOut() }
                        moreMenuItem("重置缩放", "1.magnifyingglass") { actions.resetZoom() }
                        moreMenuItem("打印…", "printer") { actions.printPage() }
                        Divider()
                        moreMenuItem("检查元素", "ladybug") { actions.inspectElement() }
                        moreMenuItem("全屏", "arrow.up.left.and.arrow.down.right") { actions.toggleFullScreen() }
                        moreMenuItem("偏好设置…", "gearshape") { showSettings = true }
                    }
                .padding(4)
                .frame(width: 200)
        }
    }
}


    .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(.bar)
        .popover(isPresented: $showPasswords) {
            PasswordPanel(passwordStore: passwordStore)
        }
        .onChange(of: isUrlFocused.wrappedValue) { _, focused in
            if !focused { suggestionModel.reset() }
        }
    }

    private var isBookmarked: Bool {
        guard let url = tab.browser.webView.url?.absoluteString else { return false }
        return bookmarkStore.contains(url: url)
    }

    private func moreMenuItem(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            showMoreMenu = false
            action()
        }) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(8)
    }
}

private struct BackForwardButton: View {
    enum Direction { case back, forward }
    let direction: Direction
    let webView: WKWebView
    let canGo: Bool
    let action: () -> Void

    private var list: [WKBackForwardListItem] {
        direction == .back ? webView.backForwardList.backList.reversed()
                           : webView.backForwardList.forwardList
    }

    private var systemName: String {
        direction == .back ? "chevron.left" : "chevron.right"
    }

    private var help: String {
        direction == .back ? "后退" : "前进"
    }

    var body: some View {
        CapsuleButton(systemName: systemName, action: action, disabled: !canGo, help: help)
            .contextMenu {
                if list.isEmpty {
                    Text(direction == .back ? "没有历史记录" : "没有前进记录")
                }
                ForEach(list, id: \.url) { item in
                    Button(item.title ?? item.url.absoluteString) {
                        webView.go(to: item)
                    }
                }
            }
    }
}

private struct DownloadButton: View {
    @ObservedObject var store: DownloadStore
    @Binding var showDownloads: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            showDownloads.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: store.hasActive ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(store.hasActive ? Color.accentColor : .primary)
                if store.activeCount > 0 {
                    Text("\(store.activeCount)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                        .offset(x: 7, y: -7)
                }
            }
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("下载")
        .onHover { isHovering = $0 }
        .popover(isPresented: $showDownloads) {
            DownloadPanel(store: store)
        }
    }
}
