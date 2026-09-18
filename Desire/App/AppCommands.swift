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
            Divider()
            Button("Close Tab") { postCommand(.closeTab) }
                .keyboardShortcut(binding("closeTab", "w", .command))
            Button("Reopen Closed Tab") { postCommand(.reopenClosedTab) }
                .keyboardShortcut(binding("reopenClosedTab", "t", [.command, .shift]))
            Divider()
            Button("Save Page…") { postCommand(.savePage) }
                .keyboardShortcut(binding("savePage", "s", .command))
        }

        // MARK: - Edit (add Find after pasteboard)

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in Page…") { postCommand(.toggleFind) }
                .keyboardShortcut(binding("findInPage", "f", .command))
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
            Button("Enter Full Screen") { postCommand(.toggleFullScreen) }
                .keyboardShortcut(binding("toggleFullScreen", "f", [.control, .command]))
            Divider()
            Button("Reload Page") { postCommand(.reload) }
                .keyboardShortcut(binding("reload", "r", .command))
            Button("Force Reload Page") { postCommand(.forceReload) }
                .keyboardShortcut(binding("forceReload", "r", [.command, .shift]))
            Button("Reader View") { postCommand(.toggleReader) }
            Divider()
            Button("Safari Web Inspector") { postCommand(.inspectElement) }
                .keyboardShortcut(binding("inspectElement", "i", [.command, .shift]))
            Button("Responsive Design Mode") { postCommand(.toggleResponsiveMode) }
                .keyboardShortcut(binding("responsiveMode", "m", [.command, .shift]))
            Divider()
            Button("Show Downloads") { postCommand(.showDownloads) }
                .keyboardShortcut(binding("showDownloads", "j", .command))
        }

        // MARK: - History

        CommandMenu("History") {
            Button("Show History") { postCommand(.showHistory) }
                .keyboardShortcut(binding("showHistory", "y", .command))
            Divider()
            Button("Clear History…") { postCommand(.clearHistory) }
        }

        // MARK: - Bookmarks

        CommandMenu("Bookmarks") {
            Button("Bookmarks Panel") { postCommand(.showBookmarks) }
                .keyboardShortcut(binding("showBookmarks", "b", .command))
            Divider()
            Button("Add Bookmark") { postCommand(.bookmarkPage) }
                .keyboardShortcut(binding("bookmarkPage", "d", .command))
        }

        // MARK: - Tabs

        CommandMenu("Tabs") {
            Button("Search Tabs") { postCommand(.tabSearch) }
                .keyboardShortcut(binding("tabSearch", "\\", .command))
            Button("Sidebar") { postCommand(.toggleSidebar) }
                .keyboardShortcut(binding("toggleSidebar", "b", [.command, .shift]))
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
            Button("Export Bookmarks…") { postCommand(.exportBookmarks) }
            Menu("Import Bookmarks") {
                Button("From Safari…") { postCommand(.importBookmarksFrom(.safari)) }
                Button("From Chrome…") { postCommand(.importBookmarksFrom(.chrome)) }
                Button("From Firefox…") { postCommand(.importBookmarksFrom(.firefox)) }
                Button("From HTML File…") { postCommand(.importBookmarksFrom(.html)) }
            }
            Divider()
            Button("Print…") { postCommand(.printPage) }
                .keyboardShortcut(binding("print", "p", .command))
            Button("Screenshot Region…") { postCommand(.screenshot) }
                .keyboardShortcut(binding("screenshot", "5", [.command, .shift]))
            Divider()
            Button("Restore Archived Session…") { postCommand(.restoreArchivedSession) }
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
}
