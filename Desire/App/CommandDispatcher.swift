import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Routes `BrowserCommand` values (broadcast on the `CommandBus` by the
/// menu commands in `DesireApp` and by AI tools) to the right store action
/// or UI flag.
///
/// Extracted from `ContentView`'s command handler —
/// see `docs/ARCHITECTURE.md` (L1-1). This is a value type so it captures
/// its dependencies by construction; `ContentView` rebuilds it each render
/// from current state, which is cheap.
///
/// Design notes:
/// - **`show*` flags stay on `ContentView`** as `@State`; they're passed in
///   as `Binding` so this type can flip them without owning them. A future
///   `UIState` object (roadmap Group G) will replace the binding bag.
/// - **Leaf actions** (`toggleBookmark`, `newWindow`, `navigateToURL`, …)
///   are injected as closures via `Actions` rather than moved here, because
///   they are deeply coupled to `ContentView`'s other state and stores.
///   `newWindow` in particular needs the shared `AppState`, which the
///   dispatcher deliberately doesn't retain. This keeps the extraction
///   mechanical and reversible.
@MainActor
struct CommandDispatcher {
    let tabManager: TabManager
    let settings: Settings
    let contentBlocker: ContentBlockerStore
    let videoAdBlocker: VideoAdBlocker
    let bookmarkStore: BookmarkStore
    let historyStore: HistoryStore
    let openSettings: () -> Void
    var bindings: Bindings
    var actions: Actions

    struct Bindings {
        var showHistory: Binding<Bool>
        var showBookmarks: Binding<Bool>
        var showPlugins: Binding<Bool>
        var showExtensions: Binding<Bool>
        var showElementBlock: Binding<Bool>
        var showTabSwitcher: Binding<Bool>
        var showSidebar: Binding<Bool>
        var isFindBarVisible: Binding<Bool>
        var showDownloads: Binding<Bool>
    }

    struct Actions {
        var newWindow: () -> Void
        var toggleBookmark: () -> Void
        var toggleFullScreen: () -> Void
        var showFindBar: () -> Void
        var hideFindBar: () -> Void
        var printPage: () -> Void
        var startScreenshot: () -> Void
        /// Resign address-bar focus. Backed by a `@FocusState`, which exposes
        /// a `FocusState<Bool>.Binding` that isn't convertible to
        /// `Binding<Bool>`, so it rides along as a closure.
        var clearUrlFocus: () -> Void
    }

    func handle(_ command: BrowserCommand) {
        switch command {
        case .newWindow:
            actions.newWindow()

        case .newTab:
            tabManager.addTab(
                javaScriptEnabled: settings.isJavaScriptEnabled,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker,
                autoPlayPolicy: settings.autoPlayPolicy,
                newTabPosition: settings.newTabPosition
            )
            bindings.showTabSwitcher.wrappedValue = false

        case .newIncognitoTab:
            tabManager.addTab(
                incognito: true,
                javaScriptEnabled: settings.isJavaScriptEnabled,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker,
                autoPlayPolicy: settings.autoPlayPolicy,
                newTabPosition: settings.newTabPosition
            )
            bindings.showTabSwitcher.wrappedValue = false

        case .closeTab:
            let count = tabManager.tabs.count
            if settings.confirmCloseMultipleTabs && count > 1 {
                let alert = NSAlert()
                alert.messageText = String(localized: "Close Tab")
                alert.informativeText = String(localized: "Are you sure you want to close this tab?")
                alert.addButton(withTitle: String(localized: "Close"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                if alert.runModal() == .alertFirstButtonReturn {
                    tabManager.closeTab(at: tabManager.selectedIndex)
                }
            } else {
                tabManager.closeTab(at: tabManager.selectedIndex)
            }

        case .reopenClosedTab:
            tabManager.reopenLastClosedTab(
                javaScriptEnabled: settings.isJavaScriptEnabled,
                contentBlocker: contentBlocker,
                videoAdBlocker: videoAdBlocker,
                autoPlayPolicy: settings.autoPlayPolicy
            )

        case .selectTab(let index):
            actions.clearUrlFocus()
            tabManager.selectTab(at: index)

        case .showHistory:
            bindings.showHistory.wrappedValue = true

        case .previousTab:
            guard tabManager.selectedIndex > 0 else { return }
            actions.clearUrlFocus()
            tabManager.selectTab(at: tabManager.selectedIndex - 1)

        case .nextTab:
            guard tabManager.selectedIndex < tabManager.tabs.count - 1 else { return }
            actions.clearUrlFocus()
            tabManager.selectTab(at: tabManager.selectedIndex + 1)

        case .bookmarkPage:
            actions.toggleBookmark()

        case .toggleFullScreen:
            actions.toggleFullScreen()

        case .toggleFind:
            if bindings.isFindBarVisible.wrappedValue {
                actions.hideFindBar()
            } else {
                actions.showFindBar()
            }

        case .tabSearch:
            bindings.showTabSwitcher.wrappedValue.toggle()
            if bindings.showTabSwitcher.wrappedValue {
                actions.clearUrlFocus()
            }

        case .toggleSidebar:
            bindings.showSidebar.wrappedValue.toggle()

        case .toggleResponsiveMode:
            if let tab = tabManager.selectedTab {
                tab.responsiveConfig.isEnabled.toggle()
            }

        case .showBookmarks:
            bindings.showBookmarks.wrappedValue = true

        case .showPlugins:
            bindings.showPlugins.wrappedValue = true

        case .showExtensions:
            bindings.showExtensions.wrappedValue = true

        case .showElementBlock:
            bindings.showElementBlock.wrappedValue = true

        case .showSettings:
            openSettings()

        case .reload:
            if let tab = tabManager.selectedTab { tab.browser.webView.reload() }

        case .forceReload:
            if let tab = tabManager.selectedTab { tab.browser.webView.reloadFromOrigin() }

        case .showDownloads:
            bindings.showDownloads.wrappedValue = true

        case .inspectElement:
            if let tab = tabManager.selectedTab, !tab.isOnNewTabPage {
                tab.browser.webView.requestInspector()
            }

        case .printPage:
            actions.printPage()

        case .zoomIn:
            guard let tab = tabManager.selectedTab else { return }
            let newZoom = min(5.0, max(0.5, tab.browser.pageZoom + 0.1))
            tab.browser.pageZoom = newZoom
            tab.browser.webView.pageZoom = newZoom

        case .zoomOut:
            guard let tab = tabManager.selectedTab else { return }
            let newZoom = min(5.0, max(0.5, tab.browser.pageZoom - 0.1))
            tab.browser.pageZoom = newZoom
            tab.browser.webView.pageZoom = newZoom

        case .actualSize:
            guard let tab = tabManager.selectedTab else { return }
            tab.browser.pageZoom = 1.0
            tab.browser.webView.pageZoom = 1.0

        case .clearHistory:
            historyStore.clearAll()

        case .toggleReader:
            guard let tab = tabManager.selectedTab else { return }
            if tab.browser.isReadingMode {
                tab.browser.isReadingMode = false
                tab.browser.isReaderLoading = false
            } else {
                // Extract FIRST, swap the view in on completion. Setting
                // isReadingMode before evaluating removed the WKWebView from
                // the hierarchy — WebKit then suspends the page, the
                // extraction JS never runs and the spinner stuck forever.
                tab.browser.isReaderLoading = true
                tab.browser.webView.evaluateJavaScript("window._desireReader()") { [weak tab] _, _ in
                    Task { @MainActor [weak tab] in
                        guard let tab else { return }
                        tab.browser.isReadingMode = true
                    }
                }
            }

        case .exportBookmarks:
            bookmarkStore.exportToHTML()

        case .importBookmarksFrom(let source):
            if let bookmarks = BookmarkImportService.importBookmarks(from: source), !bookmarks.isEmpty {
                bookmarkStore.saveImported(bookmarks)
            }

        case .screenshot:
            actions.startScreenshot()
        case .restoreArchivedSession:
            restoreArchivedSession()
        }
    }

    /// Tools ▸ Restore Archived Session… — picks a session file from
    /// `session-archives/` and replaces the ACTIVE window's tabs with it
    /// (double confirmation: file picker + alert).
    private func restoreArchivedSession() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Restore Archived Session")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = DiskStore.directory.appendingPathComponent("session-archives", isDirectory: true)
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let session = try? JSONDecoder().decode(SavedSession.self, from: Data(contentsOf: url)) else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't read this session file")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore this session?")
        alert.informativeText = String(localized: "The current window's tabs will be replaced by the archived session.")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        tabManager.apply(
            session: session,
            javaScriptEnabled: settings.isJavaScriptEnabled,
            contentBlocker: contentBlocker,
            videoAdBlocker: videoAdBlocker
        )
    }
}
