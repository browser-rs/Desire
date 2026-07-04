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
            CommandGroup(replacing: .newItem) {
                Button("新建标签页") {
                    postCommand(.newTab)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("新建无痕标签页") {
                    postCommand(.newIncognitoTab)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("标签页") {
                Button("关闭标签页") { postCommand(.closeTab) }
                    .keyboardShortcut("w", modifiers: .command)
                Button("恢复关闭的标签页") { postCommand(.reopenClosedTab) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("上一个标签页") { postCommand(.previousTab) }
                    .keyboardShortcut("{", modifiers: .command)
                Button("下一个标签页") { postCommand(.nextTab) }
                    .keyboardShortcut("}", modifiers: .command)
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("切换到标签页 \(n)") { postCommand(.selectTab(n - 1)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }

            CommandGroup(replacing: .windowArrangement) {
                Button("浏览历史") { postCommand(.showHistory) }
                    .keyboardShortcut("y", modifiers: .command)
            }
        }
    }

    private func postCommand(_ command: BrowserCommand) {
        NotificationCenter.default.post(name: .browserCommand, object: command)
    }
}

enum BrowserCommand {
    case newTab, newIncognitoTab, closeTab, previousTab, nextTab
    case reopenClosedTab, selectTab(Int), showHistory
    case bookmarkPage, toggleFullScreen, toggleFind
}

extension Notification.Name {
    static let browserCommand = Notification.Name("browserCommand")
}
