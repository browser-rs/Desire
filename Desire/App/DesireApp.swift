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
                Button("新建标签页") { postCommand(.newTab) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("新建无痕标签页") { postCommand(.newIncognitoTab) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("关闭标签页") { postCommand(.closeTab) }
                    .keyboardShortcut("w", modifiers: .command)
                Button("恢复关闭的标签页") { postCommand(.reopenClosedTab) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            // MARK: - Edit (add Find after pasteboard)
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("在页面中查找…") { postCommand(.toggleFind) }
                    .keyboardShortcut("f", modifiers: .command)
            }

            // MARK: - View
            CommandMenu("显示") {
                Button("实际大小") { postCommand(.actualSize) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("放大") { postCommand(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小") { postCommand(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("进入全屏") { postCommand(.toggleFullScreen) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Divider()
                Button("重新载入页面") { postCommand(.reload) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("阅读模式") { postCommand(.toggleReader) }
                Divider()
                Button("检查元素") { postCommand(.inspectElement) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("响应式设计模式") { postCommand(.toggleResponsiveMode) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            // MARK: - History
            CommandMenu("历史记录") {
                Button("浏览历史") { postCommand(.showHistory) }
                    .keyboardShortcut("y", modifiers: .command)
                Divider()
                Button("清除历史…") { postCommand(.clearHistory) }
            }

            // MARK: - 书签
            CommandMenu("书签") {
                Button("书签面板") { postCommand(.showBookmarks) }
                Divider()
                Button("添加书签") { postCommand(.bookmarkPage) }
                    .keyboardShortcut("d", modifiers: .command)
            }

            // MARK: - 标签页
            CommandMenu("标签页") {
                Button("搜索标签页") { postCommand(.tabSearch) }
                    .keyboardShortcut("\\", modifiers: .command)
                Button("侧边栏") { postCommand(.toggleSidebar) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
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

            // MARK: - Tools
            CommandMenu("工具") {
                Button("插件") { postCommand(.showPlugins) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("元素拦截") { postCommand(.showElementBlock) }
                Divider()
                Button("导出书签") { postCommand(.exportBookmarks) }
                Button("导入书签") { postCommand(.importBookmarks) }
                Divider()
                Button("打印…") { postCommand(.printPage) }
                    .keyboardShortcut("p", modifiers: .command)
            }

            // MARK: - Window
            CommandGroup(replacing: .windowArrangement) {
                Button("设置") { postCommand(.showSettings) }
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
}

extension Notification.Name {
    static let browserCommand = Notification.Name("browserCommand")
}
