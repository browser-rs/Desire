import AppKit
import SwiftUI

/// The app's menu commands. Observes the shared `KeyboardShortcutStore`, so
/// every mapping-backed menu item's `.keyboardShortcut` is rebuilt the moment
/// a binding is re-recorded in Settings — that is what makes the shortcuts
/// settings page REAL: no hardcoded key here survives a customization.
///
/// Items WITHOUT a mapping stay hardcoded (⌘1-9 tab switching, Esc, Reader,
/// Clear History, Plugins/Extensions, import/export — fixed conventions).
/// `savePage` has a mapping but no command yet, so it stays unwired.
///
/// Re-recorded bindings are persisted by the store and land here on the next
/// launch. Live re-binding was investigated and is NOT achievable: on
/// macOS 26 the Commands body DOES re-evaluate on store changes (verified via
/// logging), but SwiftUI never pushes the new key equivalents into the
/// installed NSMenu items — neither value diffs nor `.id()` structural
/// rebuilds update them. The Settings page says so in its subtitle.
struct AppCommands: Commands {
    @ObservedObject var shortcuts: KeyboardShortcutStore
    /// Observed so toggle-style menu titles ("Show/Hide Bookmarks Bar")
    /// track state. (Commands body re-evaluates on observed store changes —
    /// see the live-rebinding note above.)
    @ObservedObject var settings: Settings
    /// 书签栏/全部书签进菜单（Bookmarks 菜单动态区）。
    @ObservedObject var bookmarks: BookmarkStore
    /// File ▸ New Container Tab 子菜单。
    @ObservedObject var containers: ContainerStore

    var body: some Commands {
        // Replace the default .appSettings command with one that opens our
        // id-based Settings window. This puts the menu item in the right
        // place (App menu → Settings…) and binds ⌘, automatically.
        CommandGroup(replacing: .appSettings) {
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(binding("settings", ",", .command))
        }

        // MARK: - File

        CommandGroup(replacing: .newItem) {
            Button("New Window") { postCommand(.newWindow) }
                .keyboardShortcut(binding("newWindow", "n", .command))
            Button("New Tab") { postCommand(.newTab) }
                .keyboardShortcut(binding("newTab", "t", .command))
            Button("New Incognito Tab") { postCommand(.newIncognitoTab) }
                .keyboardShortcut(binding("newIncognitoTab", "n", [.command, .shift]))
            if !containers.containers.isEmpty {
                Menu("New Container Tab") {
                    ForEach(containers.containers) { container in
                        Button(container.name) { postCommand(.newContainerTab(container.id)) }
                    }
                }
            }
            Divider()
            Button("Open Location…") { postCommand(.openLocation) }
                .keyboardShortcut(binding("focusAddressBar", "l", .command))
            Button("Open File…") { postCommand(.openFile) }
                .keyboardShortcut(binding("openFile", "o", .command))
            Divider()
            Button("Close Window") { postCommand(.closeWindow) }
                .keyboardShortcut(binding("closeWindow", "w", [.command, .shift]))
            Button("Close Tab") { postCommand(.closeTab) }
                .keyboardShortcut(binding("closeTab", "w", .command))
            Button("Reopen Closed Tab") { postCommand(.reopenClosedTab) }
                .keyboardShortcut(binding("reopenClosedTab", "t", [.command, .shift]))
            Divider()
            Button("Save Page…") { postCommand(.savePage) }
                .keyboardShortcut(binding("savePage", "s", .command))
        }

        // MARK: - Edit (Find submenu after pasteboard)

        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find in Page…") { postCommand(.toggleFind) }
                    .keyboardShortcut(binding("findInPage", "f", .command))
                Divider()
                Button("Find Next") { postCommand(.findNext) }
                    .keyboardShortcut(binding("findNext", "g", .command))
                Button("Find Previous") { postCommand(.findPrevious) }
                    .keyboardShortcut(binding("findPrevious", "g", [.command, .shift]))
            }
        }

        // MARK: - View

        CommandMenu("View") {
            Button("Actual Size") { postCommand(.actualSize) }
                .keyboardShortcut(binding("resetZoom", "0", .command))
            Button("Zoom In") { postCommand(.zoomIn) }
                .keyboardShortcut(binding("zoomIn", "=", .command))
            Button("Zoom Out") { postCommand(.zoomOut) }
                .keyboardShortcut(binding("zoomOut", "-", .command))
            Divider()
            Button(settings.showBookmarksBar ? "Hide Bookmarks Bar" : "Show Bookmarks Bar") {
                postCommand(.toggleBookmarksBar)
            }
            .keyboardShortcut(binding("toggleBookmarksBar", "b", [.command, .shift]))
            Button("Split View") { postCommand(.toggleSplitView) }
                .keyboardShortcut(binding("toggleSplitView", "\\", [.command, .shift]))
            Button("Reading List") { postCommand(.showReadingList) }
                .keyboardShortcut(binding("showReadingList", "r", [.control, .command]))
            Button("Enter Full Screen") { postCommand(.toggleFullScreen) }
                .keyboardShortcut(binding("toggleFullScreen", "f", [.control, .command]))
            Divider()
            Button("Reload Page") { postCommand(.reload) }
                .keyboardShortcut(binding("reload", "r", .command))
            Button("Force Reload Page") { postCommand(.forceReload) }
                .keyboardShortcut(binding("forceReload", "r", [.command, .shift]))
            Button("Stop Loading") { postCommand(.stopLoading) }
                .keyboardShortcut(binding("stopLoading", ".", .command))
            Button("Reader View") { postCommand(.toggleReader) }
            Button("View Source") { postCommand(.viewSource) }
                .keyboardShortcut(binding("viewSource", "u", [.option, .command]))
            Divider()
            Button("Command Palette…") { postCommand(.toggleCommandPalette) }
                .keyboardShortcut(binding("commandPalette", "k", .command))
            Button("AI Agent Panel") { postCommand(.toggleAgentPanel) }
                .keyboardShortcut(binding("toggleAgentPanel", "'", .command))
            Divider()
            Button("Safari Web Inspector") { postCommand(.inspectElement) }
                .keyboardShortcut(binding("inspectElement", "i", [.command, .shift]))
            Button("Developer Tools") { postCommand(.toggleDevTools) }
                .keyboardShortcut(binding("toggleDevTools", "i", [.option, .command]))
            Button("Responsive Design Mode") { postCommand(.toggleResponsiveMode) }
                .keyboardShortcut(binding("responsiveMode", "m", [.command, .shift]))
            Divider()
            Button("Show Downloads") { postCommand(.showDownloads) }
                .keyboardShortcut(binding("showDownloads", "j", .command))
        }

        // MARK: - Agent

        CommandMenu("Agent") {
            Button("Show Agent Panel") { postCommand(.toggleAgentPanel) }
                .keyboardShortcut(binding("toggleAgentPanel", "'", .command))
            Button("Ask Agent About This Page") { postCommand(.askAgentAboutPage) }
                .keyboardShortcut(binding("askAgentAboutPage", "a", [.command, .shift]))
            Divider()
            Button("Command Palette…") { postCommand(.toggleCommandPalette) }
                .keyboardShortcut(binding("commandPalette", "k", .command))
        }

        // MARK: - History

        CommandMenu("History") {
            Button("Back") { postCommand(.goBack) }
                .keyboardShortcut(binding("goBack", "[", .command))
            Button("Forward") { postCommand(.goForward) }
                .keyboardShortcut(binding("goForward", "]", .command))
            Divider()
            Button("Show History") { postCommand(.showHistory) }
                .keyboardShortcut(binding("showHistory", "y", .command))
            Divider()
            Button("Clear History…") { postCommand(.clearHistory) }
        }

        // MARK: - Bookmarks

        CommandMenu("Bookmarks") {
            Button("Bookmarks Panel") { postCommand(.showBookmarks) }
                .keyboardShortcut(binding("showBookmarks", "b", .command))
            Button("Add Bookmark") { postCommand(.bookmarkPage) }
                .keyboardShortcut(binding("bookmarkPage", "d", .command))
            Button("Add to Reading List") { postCommand(.addToReadingList) }
            Divider()
            Button("Export Bookmarks…") { postCommand(.exportBookmarks) }
            Menu("Import Bookmarks") {
                Button("From Safari…") { postCommand(.importBookmarksFrom(.safari)) }
                Button("From Chrome…") { postCommand(.importBookmarksFrom(.chrome)) }
                Button("From Firefox…") { postCommand(.importBookmarksFrom(.firefox)) }
                Button("From HTML File…") { postCommand(.importBookmarksFrom(.html)) }
            }
            if !bookmarks.bookmarks.isEmpty {
                Divider()
                // 全部书签（树结构：文件夹进子菜单，叶子直达）。
                bookmarkTreeSection(bookmarks.bookmarks)
            }
        }

        // MARK: - Tabs

        CommandMenu("Tabs") {
            Button("Search Tabs") { postCommand(.tabSearch) }
                .keyboardShortcut(binding("tabSearch", "\\", .command))
            Button("Sidebar") { postCommand(.toggleSidebar) }
                .keyboardShortcut(binding("toggleSidebar", "b", [.control, .command]))
            Divider()
            Button("Previous Tab") { postCommand(.previousTab) }
                .keyboardShortcut(binding("previousTab", "[", [.command, .shift]))
            Button("Next Tab") { postCommand(.nextTab) }
                .keyboardShortcut(binding("nextTab", "]", [.command, .shift]))
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
            Button("Extensions") { postCommand(.showExtensions) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Element Blocker") { postCommand(.showElementBlock) }
            Divider()
            Button("Print…") { postCommand(.printPage) }
                .keyboardShortcut(binding("print", "p", .command))
            Button("Screenshot Region…") { postCommand(.screenshot) }
                .keyboardShortcut(binding("screenshot", "5", [.command, .shift]))
            Button("Full-Page Screenshot") { postCommand(.fullPageScreenshot) }
            Divider()
            Button("Restore Archived Session…") { postCommand(.restoreArchivedSession) }
        }

        // MARK: - Help

        CommandGroup(replacing: .help) {
            Button("Desire on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/browser-rs/Desire")!)
            }
            Button("Release Notes") {
                NSWorkspace.shared.open(URL(string: "https://github.com/browser-rs/Desire/releases")!)
            }
            Button("Automation Bridge Docs") {
                NSWorkspace.shared.open(URL(string: "https://github.com/browser-rs/Desire/blob/main/docs/BRIDGE.md")!)
            }
        }

        // MARK: - Window

        CommandGroup(replacing: .windowArrangement) {
            Button("Settings…") { postCommand(.showSettings) }
                .keyboardShortcut(binding("settings", ",", .command))
        }
    }

    /// Store-driven shortcut for `id`, falling back to the built-in default
    /// when the mapping is missing (unknown ids must not silently unbind a
    /// menu item).
    private func binding(_ id: String, _ fallbackKey: Character, _ fallbackModifiers: EventModifiers) -> KeyboardShortcut {
        shortcuts.keyboardShortcut(for: id)
            ?? KeyboardShortcut(KeyEquivalent(fallbackKey), modifiers: fallbackModifiers)
    }

    private func postCommand(_ command: BrowserCommand) {
        CommandBus.shared.send(command)
    }

    /// Bookmarks 菜单的书签树：文件夹递归成子菜单，叶子直接导航。
    /// 递归视图必须 AnyView 擦除（opaque type 无法自引用）。
    private func bookmarkTreeSection(_ items: [Bookmark]) -> AnyView {
        AnyView(ForEach(items) { bookmark in
            if bookmark.isFolder, !bookmark.children.isEmpty {
                AnyView(Menu(bookmark.title.isEmpty ? "Untitled Folder" : bookmark.title) {
                    bookmarkTreeSection(bookmark.children)
                })
            } else if let url = bookmark.url {
                AnyView(Button(bookmark.title.isEmpty ? url : bookmark.title) {
                    postCommand(.openURL(url))
                })
            } else {
                AnyView(EmptyView())
            }
        })
    }
}
