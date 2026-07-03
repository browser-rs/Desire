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
                Button("") { isUrlFocused = true }
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
            }

            ProgressView(value: browser.estimatedProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(height: isLoading ? 2 : 0)
                .opacity(isLoading ? 1 : 0)

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
