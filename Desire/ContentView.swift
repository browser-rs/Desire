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

    @State private var isFindBarVisible = false
    @State private var findString = ""
    @State private var findMatchCount = 0

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
                        canGoForward: Binding(get: { tab.canGoForward }, set: { tab.canGoForward = $0 })
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onReceive(tabManager.$selectedIndex) { _ in
            if let tab = tabManager.selectedTab {
                NSApp.mainWindow?.title = tab.browser.pageTitle
            }
        }
        .onAppear {
            if tabManager.tabs.isEmpty {
                tabManager.addTab()
            }
        }
        .overlay {
            Button("") { tabManager.addTab() }
                .keyboardShortcut("t", modifiers: .command)
                .hidden()
            Button("") {
                if let tab = tabManager.selectedTab {
                    tabManager.closeTab(at: tabManager.selectedIndex)
                }
            }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabButton(for: tab, at: index)
                    }
                }
            }

            Button(action: { tabManager.addTab() }) {
                Image(systemName: "plus")
                    .font(.caption)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .padding(.leading, 4)
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

    private func toolbar(for tab: Tab) -> some View {
        HStack(spacing: 6) {
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
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            )

            if tab.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(8)
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

    private func loadHome(for tab: Tab) {
        tab.browser.webView.load(URLRequest(url: URL(string: "https://www.google.com")!))
    }

    private func navigateToURL(_ input: String, for tab: Tab) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            if text.contains(".") {
                text = "https://" + text
            } else {
                text = "https://www.google.com/search?q=" + text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
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

            if findMatchCount > 0 && !findString.isEmpty {
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

    private func showFindBar() {
        findString = ""
        findMatchCount = 0
        isFindBarVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFindFocused = true
        }
    }

    private func hideFindBar() {
        isFindBarVisible = false
        findString = ""
        findMatchCount = 0
        NSApp.mainWindow?.makeFirstResponder(nil)
    }

    private func performFindAll() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else {
            findMatchCount = 0
            return
        }
        let config = WKFindConfiguration()
        config.wraps = false
        tab.browser.webView.find(findString, configuration: config) { result in
            findMatchCount = result.matchFound ? 1 : 0
        }
    }

    private func performFindNext() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.wraps = true
        findMatchCount = 1
        tab.browser.webView.find(findString, configuration: config) { _ in }
    }

    private func performFindPrevious() {
        guard let tab = tabManager.selectedTab, !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = true
        config.wraps = true
        findMatchCount = 1
        tab.browser.webView.find(findString, configuration: config) { _ in }
    }
}
