//
//  DesireApp.swift
//  Desire
//
//  Created by mankong on 2026/7/3.
//

import SwiftUI

@main
struct DesireApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // MARK: - File
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { postCommand(.newTab) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Incognito Tab") { postCommand(.newIncognitoTab) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Close Tab") { postCommand(.closeTab) }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Reopen Closed Tab") { postCommand(.reopenClosedTab) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            // MARK: - Edit (add Find after pasteboard)
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find in Page…") { postCommand(.toggleFind) }
                    .keyboardShortcut("f", modifiers: .command)
            }

            // MARK: - View
            CommandMenu("View") {
                Button("Actual Size") { postCommand(.actualSize) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Zoom In") { postCommand(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { postCommand(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("Enter Full Screen") { postCommand(.toggleFullScreen) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Divider()
                Button("Reload Page") { postCommand(.reload) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Reader View") { postCommand(.toggleReader) }
                Divider()
                Button("Inspect Element") { postCommand(.inspectElement) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Responsive Design Mode") { postCommand(.toggleResponsiveMode) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            // MARK: - History
            CommandMenu("History") {
                Button("Show History") { postCommand(.showHistory) }
                    .keyboardShortcut("y", modifiers: .command)
                Divider()
                Button("Clear History…") { postCommand(.clearHistory) }
            }

            // MARK: - Bookmarks
            CommandMenu("Bookmarks") {
                Button("Bookmarks Panel") { postCommand(.showBookmarks) }
                Divider()
                Button("Add Bookmark") { postCommand(.bookmarkPage) }
                    .keyboardShortcut("d", modifiers: .command)
            }

            // MARK: - Tabs
            CommandMenu("Tabs") {
                Button("Search Tabs") { postCommand(.tabSearch) }
                    .keyboardShortcut("\\", modifiers: .command)
                Button("Sidebar") { postCommand(.toggleSidebar) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Previous Tab") { postCommand(.previousTab) }
                    .keyboardShortcut("{", modifiers: .command)
                Button("Next Tab") { postCommand(.nextTab) }
                    .keyboardShortcut("}", modifiers: .command)
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Switch to Tab \(n)") { postCommand(.selectTab(n - 1)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }

            // MARK: - Tools
            CommandMenu("Tools") {
                Button("Plugins") { postCommand(.showPlugins) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Element Blocker") { postCommand(.showElementBlock) }
                Divider()
                Button("Export Bookmarks…") { postCommand(.exportBookmarks) }
                Button("Import Bookmarks…") { postCommand(.importBookmarks) }
                Divider()
                Button("Print…") { postCommand(.printPage) }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Screenshot Region…") { postCommand(.screenshot) }
                    .keyboardShortcut("5", modifiers: [.command, .shift])
            }

            // MARK: - Window
            CommandGroup(replacing: .windowArrangement) {
                Button("Settings…") { postCommand(.showSettings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func postCommand(_ command: BrowserCommand) {
        NotificationCenter.default.post(name: .browserCommand, object: command)
    }
}

enum BrowserCommand {
    case newTab, newIncognitoTab, closeTab, previousTab, nextTab
    case reopenClosedTab, selectTab(Int)
    case showHistory, showBookmarks, showSettings
    case showPlugins, showElementBlock
    case bookmarkPage, toggleFullScreen, toggleFind, tabSearch, toggleSidebar
    case toggleResponsiveMode, toggleReader
    case reload, inspectElement, printPage
    case zoomIn, zoomOut, actualSize
    case clearHistory, exportBookmarks, importBookmarks
    case screenshot
}

extension Notification.Name {
    static let browserCommand = Notification.Name("browserCommand")
}
