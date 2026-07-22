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
        let toggleAIFloatingPanel: () -> Void
        let toggleDevTools: () -> Void
    }

    @ObservedObject var tab: Tab
    let settings: Settings
    let isReadingMode: Bool
    @ObservedObject var suggestionModel: AddressSuggestionsModel
    let downloadStore: DownloadStore
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    let passwordStore: PasswordStore
    @ObservedObject var siteSettingsStore: SiteSettingsStore
    @ObservedObject var devToolsStore: DevToolsStore
    var isUrlFocused: FocusState<Bool>.Binding
    let actions: Actions
    @Binding var showHistory: Bool
    @Binding var showBookmarks: Bool
    @Binding var showPlugins: Bool
    @Binding var showReadingList: Bool
    @Binding var showElementBlock: Bool
    @Binding var showSearchHistory: Bool
    let openWindow: (String) -> Void

    @State private var showDownloads = false
    @State private var showPasswords = false
    @State private var showMoreMenu = false
    @State private var showSecurityInfo = false
    /// Cached bookmark-state for the current page, recomputed only when the
    /// page URL or the bookmark set changes — not on every body evaluation.
    /// `bookmarkStore.contains` is O(1) (URL index), but recomputing it 3×
    /// per render still allocates; this keeps the hot path allocation-free.
    @State private var isBookmarked = false
    /// Local editing buffer for the address field. Binding the field directly
    /// to `tab.urlString` (a `@Published` property observed by this view)
    /// created a feedback loop: each keystroke wrote `tab.urlString`, which
    /// fired `tab.objectWillChange`, which re-evaluated `body`, which rebuilt
    /// `URLBarField` and disrupted the NSTextField's field editor mid-edit
    /// (broken input). The local buffer keeps typing off the publish path;
    /// it only commits to `tab.urlString` on submit / paste-and-go, and is
    /// refreshed from the page URL when not actively editing.
    @State private var editingURL: String = ""

    private var zoomPercent: String {
        let pct = Int((tab.browser.pageZoom * 100).rounded())
        return "\(pct)%"
    }

    /// Recomputes `isBookmarked` from the current page URL. Idempotent; cheap.
    private func refreshBookmarkState() {
        guard let url = tab.browser.webView.url?.absoluteString else {
            isBookmarked = false
            return
        }
        isBookmarked = bookmarkStore.contains(url: url)
    }

    private var isDarkMode: Bool {
        guard let host = tab.browser.webView.url?.host else { return false }
        return siteSettingsStore.darkModeEnabled(for: host)
    }

    /// What the address field should show when not actively editing: the
    /// current page URL, or the tab's `urlString` for pages that haven't
    /// committed yet (new tab, in-flight navigation).
    private var displayedURL: String {
        if let url = tab.browser.webView.url?.absoluteString, !url.isEmpty {
            return url
        }
        return tab.isOnNewTabPage ? "" : tab.urlString
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
            if focused {
                // Entering edit mode: seed the buffer with what's currently
                // displayed so the user edits the visible URL.
                editingURL = displayedURL
            } else {
                suggestionModel.reset()
                // Leaving edit mode: revert to the page URL. Submit/escape
                // handlers already committed or reverted as needed; this
                // covers the click-away case.
                editingURL = displayedURL
            }
        }
        .onAppear {
            editingURL = displayedURL
            refreshBookmarkState()
        }
        // When the page navigates (and the field is not focused), keep the
        // address field in sync with the new URL.
        .onChange(of: displayedURL) { _, value in
            if !isUrlFocused.wrappedValue { editingURL = value }
        }
        .onChange(of: tab.browser.webView.url) { _, _ in refreshBookmarkState() }
        .onChange(of: bookmarkStore.bookmarks) { _, _ in refreshBookmarkState() }
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
                text: $editingURL,
                isFocused: isUrlFocused,
                onSubmit: {
                    let target = editingURL
                    tab.urlString = target
                    actions.navigate(target)
                },
                onPasteAndGo: {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        editingURL = str
                        tab.urlString = str
                        actions.navigate(str)
                    }
                },
                onMoveSelection: { delta in suggestionModel.moveSelection(by: delta) },
                onEscape: {
                    suggestionModel.reset()
                    isUrlFocused.wrappedValue = false
                    // Restore the field to the current page URL on escape.
                    editingURL = displayedURL
                },
                onTextChange: { newValue in
                    suggestionModel.build(query: newValue, settings: settings, bookmarks: bookmarkStore, history: historyStore)
                }
            )

            HoverIcon(systemName: isReadingMode ? "doc.text.fill" : "doc.text", action: actions.toggleReader, disabled: tab.isOnNewTabPage, help: isReadingMode ? "Exit Reader Mode" : "Reader Mode")
                .foregroundStyle(isReadingMode ? Color.accentColor : .secondary)

            HoverIcon(systemName: isBookmarked ? "bookmark.fill" : "bookmark", action: actions.toggleBookmark, disabled: tab.isOnNewTabPage, help: isBookmarked ? "Remove Bookmark" : "Bookmark This Page")
                .foregroundStyle(isBookmarked ? Color.accentColor : .secondary)

            searchEngineButton
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

    private var searchEngineButton: some View {
        Menu {
            ForEach(SearchEngine.allCases, id: \.self) { engine in
                Button {
                    settings.searchEngine = engine
                } label: {
                    HStack {
                        Text(engine.rawValue)
                        if settings.searchEngine == engine {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            ForEach(settings.customEngines) { engine in
                Button {
                    settings.selectedCustomEngineId = engine.id
                } label: {
                    HStack {
                        Text(engine.name)
                        if settings.selectedCustomEngineId == engine.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if settings.customEngines.isEmpty {
                Text("No custom engines")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
        .help("Search Engine: \(settings.searchEngine.rawValue)")
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
            Button { actions.toggleAIFloatingPanel() } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("AI Assistant (Floating Window)")

            Button { actions.toggleDevTools() } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(devToolsStore.isDevModeEnabled ? Color.accentColor : .primary)
            .help("Developer Tools")

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
            moreMenuItem("Search History", "magnifyingglass") { showSearchHistory = true }
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
            moreMenuItem("Developer Tools", "ladybug", shortcut: "⇧⌘D") { actions.toggleDevTools() }
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
