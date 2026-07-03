//
//  ContentView.swift
//  Desire
//
//  Created by mankong on 2026/7/3.
//

import AppKit
import SwiftUI
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

    @State private var isFindBarVisible = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showBookmarks = false
    @State private var showUserScripts = false
    @State private var showMoreMenu = false
    @State private var findString = ""
    @State private var findHasMatch = false
    @State private var isFullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            if let tab = tabManager.selectedTab {
                toolbar(for: tab)

                ProgressView(value: tab.browser.estimatedProgress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: tab.isLoading ? 2 : 0)
                    .opacity(tab.isLoading ? 1 : 0)

                if isFindBarVisible {
                    findBar
                }

                if tab.isOnNewTabPage {
                    NewTabPage(urlString: Binding(
                        get: { tab.urlString },
                        set: { tab.urlString = $0 }
                    ), onNavigate: { input in
                        navigateToURL(input, for: tab)
                    })
                } else {
                    WebView(
                        state: tab.browser,
                        urlString: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }),
                        isLoading: Binding(get: { tab.isLoading }, set: { tab.isLoading = $0 }),
                        canGoBack: Binding(get: { tab.canGoBack }, set: { tab.canGoBack = $0 }),
                        canGoForward: Binding(get: { tab.canGoForward }, set: { tab.canGoForward = $0 }),
                        onOpenLinkInNewTab: { url in
                            tabManager.addTab(url: url.absoluteString, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
                        },
                        onPageFinished: { url, title in
                            if !tab.isIncognito {
                                historyStore.addEntry(url: url.absoluteString, title: title)
                            }
                            userScriptStore.injectScripts(into: tab.browser.webView)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onReceive(tabManager.$selectedIndex) { _ in
            // 标题栏已隐藏，不再设置窗口标题
        }
        .onAppear {
            if tabManager.tabs.isEmpty {
                tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
            }
            if let window = NSApp.mainWindow {
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.titleVisibility = .hidden
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
            case .newTab: tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
            case .newIncognitoTab: tabManager.addTab(incognito: true, javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker)
            case .closeTab:
                tabManager.closeTab(at: tabManager.selectedIndex)
            case .previousTab:
                guard tabManager.selectedIndex > 0 else { return }
                tabManager.selectTab(at: tabManager.selectedIndex - 1)
            case .nextTab:
                guard tabManager.selectedIndex < tabManager.tabs.count - 1 else { return }
                tabManager.selectTab(at: tabManager.selectedIndex + 1)
            case .bookmarkPage: bookmarkCurrentPage()
            case .toggleFullScreen: toggleFullScreen()
            case .toggleFind:
                if isFindBarVisible { hideFindBar() } else { showFindBar() }
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryPanel(store: historyStore, onSelect: { url in
                showHistory = false
                if let tab = tabManager.selectedTab { navigateToURL(url, for: tab) }
            }, onClose: { showHistory = false })
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, contentBlocker: contentBlocker, onDone: { showSettings = false })
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
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabButton(for: tab, at: index)
                    }
                }
            }

            Button(action: { tabManager.addTab(javaScriptEnabled: settings.isJavaScriptEnabled, contentBlocker: contentBlocker) }) {
                Image(systemName: "plus")
                    .font(.caption)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .padding(.leading, 76)
        .padding(.top, 8)
        .frame(height: 38)
        .background(.bar)
    }

    private func tabButton(for tab: Tab, at index: Int) -> some View {
        Button {
            tabManager.selectTab(at: index)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(tab.isLoading ? Color.accentColor : .clear)
                    .frame(width: 8, height: 8)

                if tab.isIncognito {
                    Image(systemName: "mask")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .font(.caption)
                    .frame(maxWidth: 140, alignment: .leading)

                if tabManager.tabs.count > 1 {
                    Button(action: { tabManager.closeTab(at: index) }) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(index == tabManager.selectedIndex ? Color(nsColor: .controlBackgroundColor) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    private func toolbar(for tab: Tab) -> some View {
        HStack(spacing: 4) {
            Button(action: { tab.browser.webView.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!tab.canGoBack)

            Button(action: { tab.browser.webView.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!tab.canGoForward)

            Button(action: { loadHome(for: tab) }) {
                Image(systemName: "house")
            }

            Button(action: {
                if tab.isLoading {
                    tab.browser.webView.stopLoading()
                } else {
                    tab.browser.webView.reload()
                }
            }) {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
            }

            HStack(spacing: 4) {
                Image(systemName: tab.browser.isSecure ? "lock.fill" : "lock.open")
                    .foregroundStyle(tab.browser.isSecure ? Color.secondary : Color.orange)
                    .imageScale(.small)
                    .padding(.leading, 4)
                TextField("搜索或输入网址", text: Binding(get: { tab.urlString }, set: { tab.urlString = $0 }))
                    .textFieldStyle(.plain)
                    .focused($isUrlFocused)
                    .onSubmit { loadURL(for: tab) }
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tab.isIncognito ? Color.purple.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(tab.isIncognito ? Color.purple.opacity(0.4) : Color.secondary.opacity(0.25))
                    )
            )
            .layoutPriority(1)

            Spacer()

            if tab.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }

            Button(action: { bookmarkCurrentPage() }) {
                Image(systemName: "bookmark")
            }
            .disabled(tab.isOnNewTabPage)

            Button {
                showMoreMenu = true
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .popover(isPresented: $showMoreMenu) {
                VStack(spacing: 0) {
                    moreMenuItem("浏览历史", "clock.arrow.circlepath") { showHistory = true }
                    moreMenuItem("书签", "bookmark") { showBookmarks = true }
                    moreMenuItem("用户脚本", "applescript") { showUserScripts = true }
                    Divider()
                    moreMenuItem(isFullScreen ? "退出全屏" : "全屏", "arrow.up.left.and.arrow.down.right") { toggleFullScreen() }
                    moreMenuItem("偏好设置…", "gearshape") { showSettings = true }
                }
                .padding(4)
                .frame(width: 200)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar)
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
            Button("") { tab.browser.webView.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
            Button("") { tab.browser.webView.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
            Button("") { tab.browser.webView.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .hidden()
            Button("") {
                tab.browser.webView.pageZoom = tab.browser.webView.pageZoom + 0.1
            }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
            Button("") {
                tab.browser.webView.pageZoom = tab.browser.webView.pageZoom - 0.1
            }
                .keyboardShortcut("-", modifiers: .command)
                .hidden()
            Button("") { tab.browser.webView.pageZoom = 1 }
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
        }
    }

    // MARK: - Find Bar

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("在页面中查找…", text: $findString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($isFindFocused)
                .onChange(of: findString) { _ in
                    performFindAll()
                }
                .onSubmit { performFindNext() }

            if findHasMatch && !findString.isEmpty {
                Text("找到匹配")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !findString.isEmpty {
                Text("未找到")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("上一条", systemImage: "chevron.up") { performFindPrevious() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)

            Button("下一条", systemImage: "chevron.down") { performFindNext() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)

            Button("完成") { hideFindBar() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { isFindFocused = true }
    }

    // MARK: - Actions

    private func addUserScript() {
        showUserScripts = false
        // Simple default script template
        userScriptStore.add(name: "新脚本", urlPattern: "*", code: "// 在此编写你的 JavaScript 代码\nconsole.log('Desire user script loaded');")
    }

    // MARK: - Actions

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

    private func toggleFullScreen() {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }

    private func bookmarkCurrentPage() {
        guard let tab = tabManager.selectedTab,
              let url = tab.browser.webView.url,
              !tab.isOnNewTabPage else { return }
        bookmarkStore.add(title: tab.browser.pageTitle, url: url.absoluteString)
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
                text = settings.searchURLTemplate + text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            }
        }
        guard let url = URL(string: text) else { return }
        tab.isOnNewTabPage = false
        tab.urlString = text
        tab.browser.webView.load(URLRequest(url: url))
    }

    private func loadURL(for tab: Tab) {
        navigateToURL(tab.urlString, for: tab)
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
}
