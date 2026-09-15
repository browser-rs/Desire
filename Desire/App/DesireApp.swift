import AppKit
import SwiftUI

@main
struct DesireApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Production observability baseline: file MetricKit crash/hang
        // diagnostics on every launch (crashes arrive the launch AFTER).
        MetricsManager.shared.start()
    }

    var body: some Scene {
        mainWindow
        settingsWindow
    }

    private var mainWindow: some Scene {
        // Value-based WindowGroup: every window carries a persistent session
        // UUID that SwiftUI restores across launches, so each window reloads
        // ITS OWN tabs (per-window session files — see
        // TabSessionCoordinator). Windows opened via `openWindow(id: "main")`
        // (⌘N) arrive with a nil value and mint a fresh UUID in onAppear.
        WindowGroup(id: "main", for: UUID.self) { $sessionID in
            ContentView(appState: appState, sessionID: $sessionID)
                .frame(minWidth: 800, minHeight: 600)
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)
        .commands { menuCommands() }
    }

    // MARK: - Settings Window
    // Uses `WindowGroup` with a stable id so we can open it via
    // `@Environment(\.openWindow)` and get a real macOS window with the
    // standard traffic-light buttons in the title bar — same as Xcode's
    // Settings window.
    private var settingsWindow: some Scene {
        WindowGroup("Settings", id: "settings") {
            SettingsView(
                settings: appState.settings,
                aiPreference: appState.aiPreference,
                contentBlocker: appState.contentBlocker,
                downloadStore: appState.downloadStore,
                formAutofillStore: appState.formAutofillStore,
                permissionStore: appState.permissionStore,
                historyStore: appState.historyStore,
                privacyModeStore: appState.privacyModeStore
            )
            .frame(minWidth: 700, idealWidth: 900, minHeight: 480, idealHeight: 600)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
    }

    @CommandsBuilder
    private func menuCommands() -> some Commands {
        // Replace the default .appSettings command with one that opens our
        // id-based Settings window. This puts the menu item in the right
        // place (App menu → Settings…) and binds ⌘, automatically.
        CommandGroup(replacing: .appSettings) {
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // MARK: - File
        CommandGroup(replacing: .newItem) {
            Button("New Window") { postCommand(.newWindow) }
                .keyboardShortcut("n", modifiers: .command)
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
            Button("Safari Web Inspector") { postCommand(.inspectElement) }
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
                .keyboardShortcut("p", modifiers: .command)
            Button("Screenshot Region…") { postCommand(.screenshot) }
                .keyboardShortcut("5", modifiers: [.command, .shift])
            Divider()
            Button("Restore Archived Session…") { postCommand(.restoreArchivedSession) }
        }

        // MARK: - Window
        CommandGroup(replacing: .windowArrangement) {
            Button("Settings…") { postCommand(.showSettings) }
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func postCommand(_ command: BrowserCommand) {
        CommandBus.shared.send(command)
    }
}

enum BrowserCommand {
    case newWindow, newTab, newIncognitoTab, closeTab, previousTab, nextTab
    case reopenClosedTab, selectTab(Int)
    case showHistory, showBookmarks, showSettings
    case showPlugins, showExtensions, showElementBlock
    case bookmarkPage, toggleFullScreen, toggleFind, tabSearch, toggleSidebar
    case toggleResponsiveMode, toggleReader
    case reload, inspectElement, printPage
    case zoomIn, zoomOut, actualSize
    case clearHistory, exportBookmarks, importBookmarksFrom(BookmarkImportService.ImportSource)
    case screenshot
    case restoreArchivedSession
}


/// Bridges NSApplication termination so per-window sessions are force-
/// persisted while the windows are still open (willTerminate fires after
/// windows begin closing — too late for a clean re-archive).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TabSessionCoordinator.shared.prepareForTermination()
        return .terminateNow
    }
}
