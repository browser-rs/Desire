import AppKit
import os
import SwiftUI

/// Cold-start instrumentation. `launchedAt` is captured at first type touch
/// (the earliest deterministic app-code moment); `markFirstWindowInteractive`
/// closes the os_signpost interval and logs elapsed wall time against the
/// 400 ms budget (warning when over).
enum StartupMetric {
    static let launchedAt = Date()
    private static var marked = false
    private static let signposter = OSSignposter(subsystem: "me.siwi.Desire", category: "app")
    private static var interval: OSSignpostIntervalState?

    /// Call as the FIRST thing in app init — anchors t0. Swift statics are
    /// lazily initialized, so `launchedAt` without this anchor would only be
    /// created at the first `mark` call, reporting a meaningless 0ms.
    static func anchorLaunch() {
        _ = launchedAt // force initialization NOW — laziness would zero the measurement
        interval = signposter.beginInterval("coldStart")
    }

    static func markFirstWindowInteractive() {
        guard !marked else { return }
        marked = true
        if let interval {
            signposter.endInterval("coldStart", interval)
        }
        let ms = Int(Date().timeIntervalSince(launchedAt) * 1000)
        if ms > 400 {
            Log.app.warning("startup: first window interactive in \(ms, privacy: .public)ms — OVER the 400ms budget")
        } else {
            Log.app.info("startup: first window interactive in \(ms, privacy: .public)ms (budget 400ms)")
        }
    }
}

@main
struct DesireApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        StartupMetric.anchorLaunch()
        // Localhost-only test automation bridge — inert unless the app is
        // launched with --automation (external drivers: curl / CI).
        AutomationServer.shared.startIfRequested()
        // Desire as an MCP server (external AI clients drive the browser) —
        // gated behind --mcp-server like the bridge's --automation.
        MCPService.shared.startIfRequested()
        // Production observability baseline: file MetricKit crash/hang
        // diagnostics on every launch (crashes arrive the launch AFTER).
        MetricsManager.shared.start()
        // GitHub Releases update check (silent when current; notification
        // click opens the release page).
        UpdateChecker.shared.checkIfNeeded()
    }

    var body: some Scene {
        mainWindow
        settingsWindow
        onboardingWindow
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
        .commands { AppCommands(
            shortcuts: appState.system.keyboardShortcutStore,
            settings: appState.settings,
            bookmarks: appState.bookmarkStore,
            containers: ContainerStore.shared
        ) }
    }

    // MARK: - Settings Window
    // Uses `WindowGroup` with a stable id so we can open it via
    // `@Environment(\.openWindow)` and get a real macOS window with the
    // standard traffic-light buttons in the title bar — same as Xcode's
    // 首启动引导（0.3.8）：只在 desire.onboardingDone 缺席时打开。
    private var onboardingWindow: some Scene {
        WindowGroup(id: "onboarding") {
            OnboardingView(onFinish: {
                NSApp.keyWindow?.close()
            })
            .appAccent(appState.settings.accentColor.color)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    // Settings window.
    private var settingsWindow: some Scene {
        WindowGroup("Settings", id: "settings") {
            SettingsView(
                settings: appState.settings,
                aiPreference: appState.aiPreference,
                syncStore: appState.syncStore,
                contentBlocker: appState.contentBlocker,
                videoAdBlocker: appState.videoAdBlocker,
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
    case reload, forceReload, inspectElement, printPage, savePage
    case zoomIn, zoomOut, actualSize
    case clearHistory, exportBookmarks, importBookmarksFrom(BookmarkImportService.ImportSource)
    case screenshot
    case restoreArchivedSession
    // 菜单补全（0.2.13）：新功能的统一入口。
    case toggleBookmarksBar, toggleCommandPalette, toggleAgentPanel
    case toggleDevTools, toggleSplitView, showReadingList, fullPageScreenshot
    // 菜单补全二批（0.2.14）：文件/查找/导航/阅读列表/Agent。
    case openLocation, openFile, closeWindow
    case findNext, findPrevious, addToReadingList, askAgentAboutPage
    case goBack, goForward
    case toggleTabOverview
    // 菜单补全三批：停止加载/查看源代码/动态菜单导航/容器标签。
    case stopLoading, viewSource
    case openURL(String)
    case newContainerTab(UUID)
}


/// Bridges NSApplication termination so per-window sessions are force-
/// persisted while the windows are still open (willTerminate fires after
/// windows begin closing — too late for a clean re-archive).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
    }

    /// SIGTERM/SIGINT → ordinary `terminate()` on the main queue. The
    /// default disposition hard-kills the process mid-teardown, which is
    /// the BUG-K hang (WebKit's threads race the exit). Routed through the
    /// same path as Cmd+Q: applicationShouldTerminate → session flush →
    /// clean exit.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN) // the dispatch source owns delivery
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Log.app.info("signal \(sig, privacy: .public) → graceful terminate")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // BUG-K diagnostics: the process occasionally hangs inside exit()
        // after termination is approved. Log everything still alive at the
        // moment we hand control back to AppKit, so a stuck run can be
        // matched against this inventory. Synchronous with a bounded wait —
        // a fire-and-forget Task loses the race against process exit.
        ShutdownDiagnostics.capture(reason: "applicationShouldTerminate")
        TabSessionCoordinator.shared.prepareForTermination()
        ShutdownDiagnostics.capture(reason: "after session flush")
        return .terminateNow
    }
}

/// Point-in-time inventory of work still in flight (BUG-K investigation).
@MainActor
enum ShutdownDiagnostics {
    static func capture(reason: String) {
        // Snapshot main-actor state FIRST — the getAllTasks completion is
        // nonisolated and cannot touch MainActor properties.
        let session = AgentScheduler.shared.deliveryTarget
        let agentBusy = session?.isProcessing ?? false
        let loopCancelled = session?.isLoopCancelled ?? true
        let downloads = AppState.live?.downloadStore
        let activeDownloads = downloads?.downloads.filter { $0.state == .inProgress }.count ?? 0
        let pausedDownloads = downloads?.pausedCount ?? 0
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.getAllTasks { tasks in
            let summary = Dictionary(grouping: tasks, by: { String(describing: type(of: $0)) })
                .map { "\($0.key): \($0.value.count)" }
                .sorted()
                .joined(separator: ", ")
            Log.app.fault("shutdown[\(reason, privacy: .public)] agentBusy=\(agentBusy) loopCancelled=\(loopCancelled) activeDownloads=\(activeDownloads) pausedDownloads=\(pausedDownloads) urlSessionTasks=[\(summary, privacy: .public)]")
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.5)
    }
}
