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
    @StateObject private var browser = BrowserState()
    @State private var urlString = "https://www.google.com"
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @FocusState private var isUrlFocused: Bool

    @State private var isFindBarVisible = false
    @State private var findString = ""
    @State private var findMatchCount = 0
    @FocusState private var isFindFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { browser.webView.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)

                Button(action: { browser.webView.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)

                Button(action: { browser.webView.load(URLRequest(url: URL(string: "https://www.google.com")!)) }) {
                    Image(systemName: "house")
                }

                Image(systemName: browser.isSecure ? "lock.fill" : "lock.open")
                    .foregroundStyle(browser.isSecure ? Color.secondary : Color.orange)
                    .imageScale(.small)

                Button(action: {
                    if isLoading {
                        browser.webView.stopLoading()
                    } else {
                        browser.webView.reload()
                    }
                }) {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                }

                TextField("请输入 URL", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .focused($isUrlFocused)
                    .onSubmit {
                        loadURL()
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
                Button("") { browser.webView.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .hidden()
                Button("") { browser.webView.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .hidden()
                Button("") { browser.webView.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .hidden()
                Button("") {
                    browser.webView.pageZoom = browser.webView.pageZoom + 0.1
                }
                    .keyboardShortcut("=", modifiers: .command)
                    .hidden()
                Button("") {
                    browser.webView.pageZoom = browser.webView.pageZoom - 0.1
                }
                    .keyboardShortcut("-", modifiers: .command)
                    .hidden()
                Button("") { browser.webView.pageZoom = 1 }
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

            ProgressView(value: browser.estimatedProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(height: isLoading ? 2 : 0)
                .opacity(isLoading ? 1 : 0)

            if isFindBarVisible {
                findBar
            }

            WebView(
                state: browser,
                urlString: $urlString,
                isLoading: $isLoading,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(browser.$pageTitle) { title in
            NSApp.mainWindow?.title = title
        }
        .onAppear {
            if browser.webView.url == nil,
               let url = URL(string: "https://www.google.com") {
                browser.webView.load(URLRequest(url: url))
                urlString = "https://www.google.com"
            }
        }
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
        guard !findString.isEmpty else {
            findMatchCount = 0
            return
        }
        let config = WKFindConfiguration()
        config.wraps = false
        browser.webView.find(findString, configuration: config) { result in
            findMatchCount = result.matchFound ? 1 : 0
        }
    }

    private func performFindNext() {
        guard !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.wraps = true
        findMatchCount = 1
        browser.webView.find(findString, configuration: config) { _ in }
    }

    private func performFindPrevious() {
        guard !findString.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = true
        config.wraps = true
        findMatchCount = 1
        browser.webView.find(findString, configuration: config) { _ in }
    }

    private func loadURL() {
        var input = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if !input.hasPrefix("http://") && !input.hasPrefix("https://") {
            input = "https://" + input
        }
        guard let url = URL(string: input) else { return }
        browser.webView.load(URLRequest(url: url))
    }
}
