import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @StateObject private var tabManager = TabManager()
    @FocusState private var isUrlFocused: Bool
    @FocusState private var isFindFocused: Bool
    @StateObject private var settings = Settings()
    @StateObject private var historyStore = HistoryStore()
    @StateObject private var bookmarkStore = BookmarkStore()
    @StateObject private var userScriptStore = UserScriptStore()
    @StateObject private var contentBlocker = ContentBlocker()
    @StateObject private var suggestionModel = AddressSuggestionsModel()
    @StateObject private var downloadStore = DownloadStore()
    @StateObject private var quickDialStore = QuickDialStore()
    @StateObject private var passwordStore = PasswordStore()
    @StateObject private var formAutofillStore = FormAutofillStore()
    @StateObject private var permissionStore = PermissionStore()
    @StateObject private var siteSettingsStore = SiteSettingsStore()
    @StateObject private var readingListStore = ReadingListStore()
    @StateObject private var tabGroupStore = TabGroupStore()
    @Environment(\.scenePhase) private var scenePhase

    @State private var isFindBarVisible = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var showUserScripts = false
    @State private var showReadingList = false
    @State private var showTabSwitcher = false
    @State private var findString = ""
    @State private var findHasMatch = false
    @State private var isFullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            if let tab = tabManager.selectedTab {
                TabBar(
                    tabs: tabManager.tabs,
                    selectedIndex: tabManager.selectedIndex,
                    isFullScreen: isFullScreen,
                    showSwitcher: showTabSwitcher,
                    onSelectTab: { index in
                        isUrlFocused = false
                        tabManager.selectTab(at: index)
                        showTabSwitcher = false
                    },
                    onCloseTab: { tabManager.closeTab(at: $0) },
                    onAddTab: {
                        tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                        showTabSwitcher = false
                    },
                    onMoveTab: { tabManager.moveTab(from: $0, to: $1) },
                    onReloadTab: { $0.browser.webView.reload() },
                    onCopyTabURL: { tab in
                        if let url = tab.browser.webView.url {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    },
                    onCloseOtherTabs: { tabManager.closeOthers(keeping: $0) },
                    onCloseTabsToRight: { tabManager.closeToTheRight(of: $0) },
                    onToggleAudioMute: { index in
                        let tab = tabManager.tabs[index]
                        tab.browser.isMuted.toggle()
                        let js = tab.browser.isMuted
                            ? "document.querySelectorAll('audio, video').forEach(e => e.muted = true)"
                            : "document.querySelectorAll('audio, video').forEach(e => e.muted = false)"
                        tab.browser.webView.evaluateJavaScript(js, completionHandler: nil)
                    },
                    onTogglePin: { index in
                        tabManager.tabs[index].isPinned.toggle()
                    },
                    tabGroupStore: tabGroupStore,
                    onCreateGroup: { index in
                        let alert = NSAlert()
                        alert.messageText = "新建标签分组"
                        alert.informativeText = "输入分组名称"
                        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
                        alert.accessoryView = tf
                        alert.addButton(withTitle: "创建")
                        alert.addButton(withTitle: "取消")
                        if alert.runModal() == .alertFirstButtonReturn {
                            let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                let group = tabGroupStore.create(name: name)
                                let tabId = tabManager.tabs[index].id
                                tabGroupStore.addTab(tabId, to: group.id)
                            }
                        }
                    }
                )

                Toolbar(
                    tab: tab,
                    settings: settings,
                    isReadingMode: tab.browser.isReadingMode,
                    suggestionModel: suggestionModel,
                    downloadStore: downloadStore,
                    bookmarkStore: bookmarkStore,
                    historyStore: historyStore,
                    passwordStore: passwordStore,
                    isUrlFocused: $isUrlFocused,
                    actions: Toolbar.Actions(
                        goBack: { tab.browser.webView.goBack() },
                        goForward: { tab.browser.webView.goForward() },
                        reload: { tab.browser.webView.reload() },
                        loadHome: { loadHome(for: tab) },
                        navigate: { input in
                            suggestionModel.reset()
                            isUrlFocused = false
                            navigateToURL(input, for: tab)
                        },
                        toggleBookmark: { toggleBookmark() },
                        toggleFullScreen: { toggleFullScreen() },
                        inspectElement: { inspectElement() },
                        suggestionSelect: { sug in
                            suggestionModel.reset()
                            isUrlFocused = false
                            navigateToURL(sug.url, for: tab)
                        },
                        printPage: { printPage() },
                        zoomIn: { zoomTab(by: 0.1) },
                        zoomOut: { zoomTab(by: -0.1) },
                        resetZoom: { zoomTab(to: 1.0) },
                        toggleReader: {
                            if tab.browser.isReadingMode {
                                tab.browser.isReadingMode = false
                            } else {
                                tab.browser.webView.evaluateJavaScript("window._desireReader()", completionHandler: nil)
                                tab.browser.isReadingMode = true
                            }
                        },
                        captureFullPage: { captureFullPage() },
                        addToReadingList: { title, url in
                            readingListStore.add(title: title, url: url)
                        },
                        togglePictureInPicture: { togglePictureInPicture() }
                    ),
                    showHistory: $showHistory,
                    showBookmarks: $showBookmarks,
                    showUserScripts: $showUserScripts,
                    showSettings: $showSettings,
                    showReadingList: $showReadingList,
                )
            }

            if let tab = tabManager.selectedTab {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(height: 2)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(tab.browser.estimatedProgress))
                        }
                }
                .frame(height: 2)
                .opacity(tab.isLoading ? 1 : 0)
                .animation(.smooth(duration: 0.15), value: tab.browser.estimatedProgress)
                .animation(.easeInOut(duration: 0.2), value: tab.isLoading)

                if isFindBarVisible {
                    FindBar(
                        findString: $findString,
                        findHasMatch: findHasMatch,
                        isFindFocused: $isFindFocused,
                        onFindNext: { performFindNext() },
                        onFindPrevious: { performFindPrevious() },
                        onHide: { hideFindBar() },
                        onFindAll: { performFindAll() }
                    )
                }

                Group {
                    if tab.browser.isReadingMode {
                        ReaderView(
                            title: tab.browser.readerTitle,
                            contentHTML: tab.browser.readerContent,
                            onClose: {
                                tab.browser.isReadingMode = false
                            }
                        )
                    } else if tab.isOnNewTabPage {
                        NewTabPage(store: quickDialStore, urlString: Binding(
                            get: { tab.urlString },
                            set: { tab.urlString = $0 }
                        ), onNavigate: { input in
                            navigateToURL(input, for: tab)
                        })
                    } else {
                        WebView(
                            state: tab.browser,
                            downloadStore: downloadStore,
                            passwordStore: passwordStore,
                            formAutofillStore: formAutofillStore,
                            permissionStore: permissionStore,
                            siteSettingsStore: siteSettingsStore,
                            urlString: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }),
                            isLoading: Binding(get: { tab.isLoading }, set: { tab.isLoading = $0 }),
                            canGoBack: Binding(get: { tab.canGoBack }, set: { tab.canGoBack = $0 }),
                            canGoForward: Binding(get: { tab.canGoForward }, set: { tab.canGoForward = $0 }),
                            onOpenLinkInNewTab: { url in
                                tabManager.addTab(url: url.absoluteString, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                            },
                            onPageFinished: { url, title in
                                if tab.suppressHistoryOnce {
                                    tab.suppressHistoryOnce = false
                                } else if !tab.isIncognito {
                                    historyStore.addEntry(url: url.absoluteString, title: title)
                                }
                                userScriptStore.injectScripts(into: tab.browser.webView)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .id(tab.id)
                .overlay(alignment: .top) {
                    if isUrlFocused && !suggestionModel.isEmpty {
                        AddressSuggestionsView(
                            model: suggestionModel,
                            engineName: settings.searchEngine.rawValue
                        ) { sug in
                            suggestionModel.reset()
                            isUrlFocused = false
                            navigateToURL(sug.url, for: tab)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
                .overlay {
                    if let error = tab.browser.lastError, !tab.isOnNewTabPage {
                        errorView(message: error, tab: tab)
                    }
                }
            }
        }
        .ignoresSafeArea(.all, edges: .top)
        .background(WindowChromeGuard())
        .onAppear {
            if tabManager.tabs.isEmpty {
                let restored = tabManager.restoreSession(
                    javaScriptEnabled: settings.isJavaScriptEnabled,
                    contentBlocker: contentBlocker
                )
                if !restored {
                    tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                tabManager.persistSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserCommand)) { notification in
            guard let command = notification.object as? BrowserCommand else { return }
            switch command {
            case .newTab:
                tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                showTabSwitcher = false
            case .newIncognitoTab:
                tabManager.addTab(incognito: true, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                showTabSwitcher = false
            case .closeTab:
                tabManager.closeTab(at: tabManager.selectedIndex)
            case .reopenClosedTab:
                tabManager.reopenLastClosedTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
            case .selectTab(let index):
                isUrlFocused = false
                tabManager.selectTab(at: index)
            case .showHistory:
                showHistory = true
            case .previousTab:
                guard tabManager.selectedIndex > 0 else { return }
                isUrlFocused = false
                tabManager.selectTab(at: tabManager.selectedIndex - 1)
            case .nextTab:
                guard tabManager.selectedIndex < tabManager.tabs.count - 1 else { return }
                isUrlFocused = false
                tabManager.selectTab(at: tabManager.selectedIndex + 1)
            case .bookmarkPage: toggleBookmark()
            case .toggleFullScreen: toggleFullScreen()
            case .toggleFind:
                if isFindBarVisible { hideFindBar() } else { showFindBar() }
            case .tabSearch:
                showTabSwitcher.toggle()
                if showTabSwitcher { isUrlFocused = false }
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryPanel(store: historyStore, onSelect: { url in
                showHistory = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onClose: { showHistory = false })
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, contentBlocker: contentBlocker, downloadStore: downloadStore, formAutofillStore: formAutofillStore, permissionStore: permissionStore, onDone: { showSettings = false })
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkPanel(store: bookmarkStore, onSelect: { url in
                showBookmarks = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onDelete: { bookmark in bookmarkStore.remove(bookmark) }, onClose: { showBookmarks = false })
        }
        .sheet(isPresented: $showUserScripts) {
            UserScriptPanel(store: userScriptStore, onAdd: addUserScript, onClose: { showUserScripts = false })
        }
        .sheet(isPresented: $showReadingList) {
            ReadingListPanel(store: readingListStore, onSelect: { url in
                showReadingList = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onClose: { showReadingList = false })
        }
        .overlay {
            Button("") {
                isUrlFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.mainWindow?.firstResponder?
                        .tryToPerform(#selector(NSTextField.selectText(_:)), with: nil)
                }
            }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.reload() } }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.goBack() } }
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
            Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.goForward() } }
                .keyboardShortcut("]", modifiers: .command)
                .hidden()
            Button("") {
                guard let tab = tabManager.selectedTab else { return }
                let newZoom = min(5.0, max(0.5, tab.browser.pageZoom + 0.1))
                tab.browser.pageZoom = newZoom
                tab.browser.webView.pageZoom = newZoom
            }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
            Button("") {
                guard let tab = tabManager.selectedTab else { return }
                let newZoom = min(5.0, max(0.5, tab.browser.pageZoom - 0.1))
                tab.browser.pageZoom = newZoom
                tab.browser.webView.pageZoom = newZoom
            }
                .keyboardShortcut("-", modifiers: .command)
                .hidden()
            Button("") {
                guard let tab = tabManager.selectedTab else { return }
                tab.browser.pageZoom = 1.0
                tab.browser.webView.pageZoom = 1.0
            }
                .keyboardShortcut("0", modifiers: .command)
                .hidden()
            Button("") { showFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("") { performFindNext() }
                .keyboardShortcut("g", modifiers: .command)
                .hidden()
            Button("") { performFindPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .hidden()
            Button("") { hideFindBar() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
            Button("") { inspectElement() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .hidden()
            Button("") { printPage() }
                .keyboardShortcut("p", modifiers: .command)
                .hidden()
        }
    }

    // MARK: - Actions

    private func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    private func errorView(message: String, tab: Tab) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("无法加载页面")
                .font(.title2)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 400)

            Button("重新加载") {
                tab.browser.lastError = nil
                if let url = URL(string: tab.urlString) {
                    tab.browser.webView.load(URLRequest(url: url))
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func toggleBookmark() {
        guard let tab = tabManager.selectedTab,
              let url = tab.browser.webView.url,
              !tab.isOnNewTabPage else { return }
        let urlString = url.absoluteString
        if let existing = bookmarkStore.find(url: urlString) {
            bookmarkStore.remove(existing)
        } else {
            bookmarkStore.add(title: tab.browser.pageTitle, url: urlString)
        }
    }

    private func inspectElement() {
        if let tab = tabManager.selectedTab, !tab.isOnNewTabPage {
            tab.browser.webView.requestInspector()
        }
    }

    private func loadHome(for tab: Tab) {
        guard let url = URL(string: settings.homePage) else { return }
        tab.isOnNewTabPage = false
        tab.urlString = settings.homePage
        tab.browser.webView.load(URLRequest(url: url))
    }

    private func navigateToURL(_ input: String, for tab: Tab) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            if text.contains(".") {
                text = "https://" + text
            } else {
                guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
                text = settings.searchURLTemplate + encoded
            }
        }
        guard let url = URL(string: text) else { return }
        tab.isOnNewTabPage = false
        tab.urlString = text
        tab.browser.webView.load(URLRequest(url: url))
    }

    private func showFindBar() {
        findString = ""
        findHasMatch = false
        isFindBarVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFindFocused = true
        }
    }

    private func hideFindBar() {
        isFindBarVisible = false
        findString = ""
        findHasMatch = false
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

    private func performFindAll() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else {
            findHasMatch = false
            return
        }
        let config = WKFindConfiguration()
        config.wraps = false
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
        }
    }

    private func performFindNext() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.wraps = true
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
        }
    }

    private func performFindPrevious() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = true
        config.wraps = true
        tab.browser.webView.find(findString, configuration: config) { result in
            findHasMatch = result.matchFound
        }
    }

    private func addUserScript() {
        showUserScripts = false
        userScriptStore.add(name: "新脚本", urlPattern: "*", code: "// 在此编写你的 JavaScript 代码\nconsole.log('Desire user script loaded');")
    }

    private func zoomTab(by delta: Double) {
        guard let tab = tabManager.selectedTab else { return }
        let newZoom = min(5.0, max(0.5, tab.browser.pageZoom + delta))
        tab.browser.pageZoom = newZoom
        tab.browser.webView.pageZoom = newZoom
        if let host = tab.browser.webView.url?.host {
            siteSettingsStore.setZoom(newZoom, for: host)
        }
    }

    private func zoomTab(to value: Double) {
        guard let tab = tabManager.selectedTab else { return }
        tab.browser.pageZoom = value
        tab.browser.webView.pageZoom = value
        if let host = tab.browser.webView.url?.host {
            siteSettingsStore.setZoom(value, for: host)
        }
    }

    private func printPage() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.topMargin = 20
        printInfo.bottomMargin = 20
        printInfo.leftMargin = 20
        printInfo.rightMargin = 20
        let operation = tab.browser.webView.printOperation(with: printInfo)
        operation.run()
    }

    private func captureFullPage() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let webView = tab.browser.webView
        let config = WKPDFConfiguration()
        webView.createPDF(configuration: config) { result in
            switch result {
            case .success(let pdfData):
                let panel = NSSavePanel()
                panel.title = "保存全页截图"
                panel.nameFieldStringValue = "\(tab.displayTitle).pdf"
                panel.allowedContentTypes = [.pdf]
                panel.begin { response in
                    if response == .OK, let url = panel.url {
                        try? pdfData.write(to: url)
                    }
                }
            case .failure:
                break
            }
        }
    }

    private func togglePictureInPicture() {
        guard let tab = tabManager.selectedTab, !tab.isOnNewTabPage else { return }
        let js = """
        (function() {
            var v = document.querySelector('video');
            if (!v) return;
            if (document.pictureInPictureElement) {
                document.exitPictureInPicture();
            } else if (v.readyState >= 2) {
                v.requestPictureInPicture();
            }
        })();
        """
        tab.browser.webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
