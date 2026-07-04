import AppKit
import SwiftUI
import WebKit

struct Toolbar: View {
    let tab: Tab
    let settings: Settings
    @ObservedObject var suggestionModel: AddressSuggestionsModel
    let downloadStore: DownloadStore
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    var isUrlFocused: FocusState<Bool>.Binding

    @Binding var showHistory: Bool
    @Binding var showBookmarks: Bool
    @Binding var showUserScripts: Bool
    @Binding var showSettings: Bool

    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onReload: () -> Void
    let onLoadHome: () -> Void
    let onNavigate: (String) -> Void
    let onToggleBookmark: () -> Void
    let onToggleFullScreen: () -> Void
    let onInspectElement: () -> Void
    let onSuggestionSelect: (AddressSuggestion) -> Void

    @State private var showDownloads = false
    @State private var showMoreMenu = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                navButton(systemName: "chevron.left") { onGoBack() }
                    .disabled(!tab.canGoBack)
                navButton(systemName: "chevron.right") { onGoForward() }
                    .disabled(!tab.canGoForward)
                navButton(systemName: "arrow.clockwise") {
                    if tab.isLoading { tab.browser.webView.stopLoading() } else { onReload() }
                }
                navButton(systemName: "house") { onLoadHome() }
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
                        onNavigate(tab.urlString)
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

                Button {
                    onToggleBookmark()
                } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 12))
                        .foregroundStyle(isBookmarked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isBookmarked ? "删除书签" : "添加书签")
                .disabled(tab.isOnNewTabPage)
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
                showDownloads.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: downloadStore.hasActive
                          ? "arrow.down.circle.fill"
                          : "arrow.down.circle")
                        .foregroundStyle(downloadStore.hasActive ? Color.accentColor : .primary)
                    if downloadStore.activeCount > 0 {
                        Text("\(downloadStore.activeCount)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(3)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                            .offset(x: 7, y: -7)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("下载")
            .popover(isPresented: $showDownloads) {
                DownloadPanel(store: downloadStore)
            }

            Button {
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis")
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
                    moreMenuItem(isBookmarked ? "删除书签" : "添加书签", isBookmarked ? "bookmark.slash" : "bookmark.fill") { onToggleBookmark() }
                        .disabled(tab.isOnNewTabPage)
                    Divider()
                    moreMenuItem("检查元素", "ladybug") { onInspectElement() }
                    moreMenuItem("全屏", "arrow.up.left.and.arrow.down.right") { onToggleFullScreen() }
                    moreMenuItem("偏好设置…", "gearshape") { showSettings = true }
                }
                .padding(4)
                .frame(width: 200)
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

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.plain)
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
