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
                Button("新建标签页") { postCommand(.newTab) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("新建无痕标签页") { postCommand(.newIncognitoTab) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("标签页") {
                Button("关闭标签页") { postCommand(.closeTab) }
                    .keyboardShortcut("w", modifiers: .command)
                Button("上一个标签页") { postCommand(.previousTab) }
                    .keyboardShortcut("{", modifiers: [.command])
                Button("下一个标签页") { postCommand(.nextTab) }
                    .keyboardShortcut("}", modifiers: [.command])
            }

            CommandMenu("书签") {
                Button("添加书签") { postCommand(.bookmarkPage) }
                    .keyboardShortcut("d", modifiers: .command)
            }

            CommandMenu("显示") {
                Button("切换全屏") { postCommand(.toggleFullScreen) }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Button("显示/隐藏查找栏") { postCommand(.toggleFind) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    private func postCommand(_ command: BrowserCommand) {
        NotificationCenter.default.post(name: .browserCommand, object: command)
    }
}

enum BrowserCommand {
    case newTab, newIncognitoTab, closeTab, previousTab, nextTab
    case bookmarkPage, toggleFullScreen, toggleFind
}

extension Notification.Name {
    static let browserCommand = Notification.Name("browserCommand")
}
