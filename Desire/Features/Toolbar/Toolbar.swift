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
        let toggleReader: () -> Void
        let captureFullPage: () -> Void
        let captureScreenshot: () -> Void
        let addToReadingList: (_ title: String, _ url: String) -> Void
        let togglePictureInPicture: () -> Void
        let toggleResponsiveMode: () -> Void
        let toggleTranslate: () -> Void
        let toggleDarkMode: () -> Void
        let toggleAIPanel: () -> Void
    }

    let tab: Tab
    let settings: Settings
    let isReadingMode: Bool
    @ObservedObject var suggestionModel: AddressSuggestionsModel
    let downloadStore: DownloadStore
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    let passwordStore: PasswordStore
    @ObservedObject var siteSettingsStore: SiteSettingsStore
    var isUrlFocused: FocusState<Bool>.Binding
    let actions: Actions
    @Binding var showHistory: Bool
    @Binding var showBookmarks: Bool
    @Binding var showPlugins: Bool
    @Binding var showReadingList: Bool
    @Binding var showElementBlock: Bool
    let openWindow: (String) -> Void

    @State private var showDownloads = false
    @State private var showPasswords = false
    @State private var showMoreMenu = false
    @State private var showSecurityInfo = false

    private var zoomPercent: String {
        let pct = Int((tab.browser.pageZoom * 100).rounded())
        return "\(pct)%"
    }

    private var isBookmarked: Bool {
        guard let url = tab.browser.webView.url?.absoluteString else { return false }
        return bookmarkStore.contains(url: url)
    }

    private var isDarkMode: Bool {
        guard let host = tab.browser.webView.url?.host else { return false }
        return siteSettingsStore.darkModeEnabled(for: host)
    }

    var body: some View {
        HStack(spacing: 12) {
            navGroup
            urlBarGroup
            zoomButton
            trailingButtons
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.bottom, 6)
        .background(.bar)
        .popover(isPresented: $showPasswords) {
            PasswordPanel(passwordStore: passwordStore)
        }
        .onChange(of: isUrlFocused.wrappedValue) { _, focused in
            if !focused { suggestionModel.reset() }
        }
    }

    // MARK: - Nav Group

    private var navGroup: some View {
        HStack(spacing: 10) {
            BackForwardButton(direction: .back, webView: tab.browser.webView, canGo: tab.canGoBack, action: actions.goBack)
            BackForwardButton(direction: .forward, webView: tab.browser.webView, canGo: tab.canGoForward, action: actions.goForward)
            CapsuleButton(systemName: tab.isLoading ? "xmark" : "arrow.clockwise", action: {
                if tab.isLoading { tab.browser.webView.stopLoading() } else { actions.reload() }
            }, help: tab.isLoading ? "Stop" : "Reload")
            CapsuleButton(systemName: "house", action: actions.loadHome, help: "Home")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - URL Bar Group

    private var urlBarGroup: some View {
        HStack(spacing: 4) {
            Button {
                showSecurityInfo.toggle()
            } label: {
                Image(systemName: tab.browser.isSecure ? "lock.fill" : "lock.open")
                    .foregroundStyle(tab.browser.isSecure ? Color.secondary : Color.orange)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(tab.browser.isSecure ? "Connection Secure" : "Connection Not Secure")
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

            HoverIcon(systemName: isReadingMode ? "doc.text.fill" : "doc.text", action: actions.toggleReader, disabled: tab.isOnNewTabPage, help: isReadingMode ? "Exit Reader Mode" : "Reader Mode")
                .foregroundStyle(isReadingMode ? Color.accentColor : .secondary)

            HoverIcon(systemName: isBookmarked ? "bookmark.fill" : "bookmark", action: actions.toggleBookmark, disabled: tab.isOnNewTabPage, help: isBookmarked ? "Remove Bookmark" : "Bookmark This Page")
                .foregroundStyle(isBookmarked ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(isUrlFocused.wrappedValue ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isUrlFocused.wrappedValue ? Color.accentColor.opacity(0.4) :
                            tab.isIncognito ? Color.purple.opacity(0.3) :
                            Color.clear, lineWidth: 0.5)
                )
                .animation(.transitionNormal, value: isUrlFocused.wrappedValue)
        )
        .layoutPriority(1)
    }

    // MARK: - Zoom Button

    private var zoomButton: some View {
        Button {
            actions.resetZoom()
        } label: {
            Text(zoomPercent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 22)
        }
        .buttonStyle(.plain)
        .help("Zoom Level — Click to reset to 100%")
    }

    // MARK: - Trailing Buttons

    private var trailingButtons: some View {
        HStack(spacing: 6) {
            DownloadButton(store: downloadStore, showDownloads: $showDownloads)

            Button {
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .rotationEffect(.degrees(90))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showMoreMenu) {
                moreMenuContent
            }
        }
    }

    // MARK: - More Menu

    private var moreMenuContent: some View {
        VStack(spacing: 0) {
            moreMenuItem("History", "clock.arrow.circlepath", shortcut: "⌘Y") { showHistory = true }
            moreMenuItem("Bookmarks", "bookmark") { showBookmarks = true }
            moreMenuItem("Passwords", "key.fill") { showPasswords = true }
            moreMenuItem("Downloads", "arrow.down.circle") { showDownloads = true }
            moreMenuItem("Reading List", "bookmark.slash") { showReadingList = true }
            moreMenuItem("Plugins", "applescript", shortcut: "⇧⌘P") { showPlugins = true }
            moreMenuItem("Element Blocker", "eye.slash") { showElementBlock = true }
            moreMenuItem(isBookmarked ? "Remove Bookmark" : "Bookmark This Page", isBookmarked ? "bookmark.slash" : "bookmark.fill", shortcut: "⌘D") { actions.toggleBookmark() }
                .disabled(tab.isOnNewTabPage)
            moreMenuItem("Add to Reading List", "bookmark.slash") {
                let url = tab.browser.webView.url?.absoluteString ?? tab.urlString
                let title = tab.browser.pageTitle
                actions.addToReadingList(title, url)
            }
            .disabled(tab.isOnNewTabPage)
            moreMenuItem("Dark Mode", isDarkMode ? "moon.circle.fill" : "moon.circle") { actions.toggleDarkMode() }
                .disabled(tab.isOnNewTabPage)
            moreMenuItem("Picture in Picture", "pip") { actions.togglePictureInPicture() }
                .disabled(tab.isOnNewTabPage)
            moreMenuItem("Share…", "square.and.arrow.up") { shareCurrentPage() }
                .disabled(tab.isOnNewTabPage)
            Divider()
            moreMenuItem("Zoom In", "plus.magnifyingglass", shortcut: "⌘=") { actions.zoomIn() }
            moreMenuItem("Zoom Out", "minus.magnifyingglass", shortcut: "⌘-") { actions.zoomOut() }
            moreMenuItem("Reset Zoom", "1.magnifyingglass", shortcut: "⌘0") { actions.resetZoom() }
            moreMenuItem("Print…", "printer", shortcut: "⌘P") { actions.printPage() }
            moreMenuItem("Full Page PDF…", "photo.on.rectangle.angled") { actions.captureFullPage() }
            moreMenuItem("Screenshot Region…", "crop", shortcut: "⇧⌘5") { actions.captureScreenshot() }
            Divider()
            moreMenuItem("Translate…", "translate") { actions.toggleTranslate() }
            moreMenuItem("Inspect Element", "ladybug", shortcut: "⇧⌘I") { actions.inspectElement() }
            moreMenuItem("Responsive Design Mode", "rectangle.on.rectangle", shortcut: "⇧⌘M") { actions.toggleResponsiveMode() }
            moreMenuItem("Full Screen", "arrow.up.left.and.arrow.down.right", shortcut: "⌃⌘F") { actions.toggleFullScreen() }
            Divider()
            moreMenuItem("AI Assistant", "wand.and.stars") { actions.toggleAIPanel() }
            moreMenuItem("Preferences…", "gearshape", shortcut: "⌘,") { openWindow("settings") }
        }
        .padding(4)
        .frame(width: 240)
    }

    private func moreMenuItem(
        _ titleKey: LocalizedStringKey,
        _ icon: String,
        shortcut: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            showMoreMenu = false
            action()
        }) {
            HStack(spacing: 6) {
                Label(titleKey, systemImage: icon)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(8)
    }

    private func shareCurrentPage() {
        guard let url = tab.browser.webView.url else { return }
        let items: [Any] = [url]
        let picker = NSSharingServicePicker(items: items)
        guard let contentView = NSApp.mainWindow?.contentView else { return }
        let rect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.maxY - 100, width: 1, height: 1)
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
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
        direction == .back ? "Back" : "Forward"
    }

    var body: some View {
        CapsuleButton(systemName: systemName, action: action, disabled: !canGo, help: help)
            .contextMenu {
                if list.isEmpty {
                    Text(direction == .back ? "No History" : "No Forward History")
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
        .help("Downloads")
        .onHover { isHovering = $0 }
        .popover(isPresented: $showDownloads) {
            DownloadPanel(store: store)
        }
    }
}
