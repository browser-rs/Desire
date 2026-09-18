import AppKit
import SwiftUI

@main
struct DesireApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Localhost-only test automation bridge — inert unless the app is
        // launched with --automation (external drivers: curl / CI).
        AutomationServer.shared.startIfRequested()
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
        .commands { AppCommands(shortcuts: appState.system.keyboardShortcutStore) }
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
                privacyModeStore: appState.privacyModeStore,
                shortcutStore: appState.system.keyboardShortcutStore
            )
            .frame(minWidth: 700, idealWidth: 900, minHeight: 480, idealHeight: 600)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
    }

    private func postCommand(_ command: BrowserCommand) {
        CommandBus.shared.send(command)
    }
}

enum BrowserCommand {
    case newWindow, newTab, newIncognitoTab, closeTab, previousTab, nextTab
    case reopenClosedTab, selectTab(Int)
    case showHistory, showBookmarks, showSettings, showDownloads
    case showPlugins, showExtensions, showElementBlock
    case bookmarkPage, toggleFullScreen, toggleFind, tabSearch, toggleSidebar
    case toggleResponsiveMode, toggleReader
    case reload, forceReload, inspectElement, printPage
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
