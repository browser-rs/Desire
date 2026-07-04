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
    }

    let tab: Tab
    let settings: Settings
    @ObservedObject var suggestionModel: AddressSuggestionsModel
    let downloadStore: DownloadStore
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    var isUrlFocused: FocusState<Bool>.Binding

    let actions: Actions

    @Binding var showHistory: Bool
    @Binding var showBookmarks: Bool
    @Binding var showUserScripts: Bool
    @Binding var showSettings: Bool

    @State private var showDownloads = false
    @State private var showMoreMenu = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                CapsuleButton(systemName: "chevron.left", action: actions.goBack, disabled: !tab.canGoBack, help: "后退")
                CapsuleButton(systemName: "chevron.right", action: actions.goForward, disabled: !tab.canGoForward, help: "前进")
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
                Image(systemName: tab.browser.isSecure ? "lock.fill" : "lock.open")
                    .foregroundStyle(tab.browser.isSecure ? Color.secondary : Color.orange)
                    .imageScale(.small)
                    .padding(.leading, 4)
                TextField("搜索或输入网址", text: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }))
                    .textFieldStyle(.plain)
                    .focused(isUrlFocused)
                    .onSubmit {
                        actions.navigate(tab.urlString)
                    }
                    .onChange(of: tab.urlString) { _, newValue in
                        if isUrlFocused.wrappedValue {
                            suggestionModel.build(query: newValue, settings: settings, bookmarks: bookmarkStore, history: historyStore)
                        }
                    }
                    .onKeyPress(.upArrow) {
                        suggestionModel.moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        suggestionModel.moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        suggestionModel.reset()
                        isUrlFocused.wrappedValue = false
                        return .handled
                    }
                    .font(.system(size: 13))

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
                    moreMenuItem("下载", "arrow.down.circle") { showDownloads = true }
                    moreMenuItem("用户脚本", "applescript") { showUserScripts = true }
                    moreMenuItem(isBookmarked ? "删除书签" : "添加书签", isBookmarked ? "bookmark.slash" : "bookmark.fill") { actions.toggleBookmark() }
                        .disabled(tab.isOnNewTabPage)
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
        .padding(.bottom, 8)
        .background(.bar)
        .onChange(of: isUrlFocused.wrappedValue) { _, focused in
            if !focused { suggestionModel.reset() }
        }
    }

    private var isBookmarked: Bool {
        guard let url = tab.browser.webView.url?.absoluteString else { return false }
        return bookmarkStore.bookmarks.contains(where: { $0.url == url })
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
