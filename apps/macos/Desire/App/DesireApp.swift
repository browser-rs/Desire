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
    /// 启动分段基准（0.6.4 性能深化）：init/didFinishLaunching/首窗 onAppear
    /// 三个相位各打一条 unified log（category app），与 632ms 基线对账用。
    /// 跨类型同文件可见（AppDelegate/ContentView 都要读）。
    static let launchStart = Date()
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Log.app.info("launch phase: app init +\(Int(Date().timeIntervalSince(DesireApp.launchStart) * 1000), privacy: .public)ms")
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
        // 0.7.0 发版 CI 实测：新 runner 镜像上 `open` 启动多 Scene 应用时
        // 主窗可能不被创建（只剩引导窗，无标签页 → 桥的浏览器端点全废）。
        // 显式声明主窗**必在启动时呈现**，不依赖镜像的隐式行为。
        .defaultLaunchBehavior(.presented)
        .commands { AppCommands(
            shortcuts: appState.system.keyboardShortcutStore,
            settings: appState.settings,
            bookmarks: appState.bookmarkStore,
            containers: ContainerStore.shared,
            aiPreference: appState.aiPreference,
            notifications: ProactiveNotificationStore.shared
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
                remoteControlStore: appState.remoteControlStore,
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
    case showPlugins, showElementBlock, showPasswordManager, showAdBlockStats
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
    case toggleWhiteboard
    case toggleAgentBall
    case addSelectionToWhiteboard
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

    /// 默认浏览器点链接 → 系统发 `openURLs` Apple event。**此前从未实现
    /// 接收端**（2026-10-02 用户实测：设为默认后点链接，app 打开但页面不
    /// 加载——URL 被静默丢弃）。冷启动时序：事件可能早于窗口/会话恢复
    /// 就绪，先入缓冲，didFinishLaunching 后多跳重试 flush。
    private var pendingOpenURLs: [URL] = []

    /// Dock 图标点击 / `open -a` 激活：**有可见窗口时返回 false**——否则
    /// SwiftUI 对 value-based WindowGroup（for: UUID.self）的 reopen 默认
    /// 行为是再 mint 一扇新主窗（实测每次 `open -a` 涨一扇 900x632）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // .board 文件（白板）：导入为当前活跃会话的白板并打开面板。
        // （双击 .board 文件 → 本应用接管。）
        let boardFiles = urls.filter { $0.pathExtension.lowercased() == "board" }
        for file in boardFiles {
            do {
                let data = try Data(contentsOf: file)
                let spec = try JSONDecoder().decode(WhiteboardSpec.self, from: data)
                let conversationID = AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
                WhiteboardStore.shared.set(spec, conversationID: conversationID)
                WhiteboardPanel.shared.show()
                Log.app.info("whiteboard imported: \(file.lastPathComponent, privacy: .public) (\(spec.blocks.count) blocks)")
            } catch {
                Log.app.error("whiteboard import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let webURLs = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
        guard !webURLs.isEmpty else { return }
        Log.app.info("open urls from system: \(webURLs.count, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        pendingOpenURLs.append(contentsOf: webURLs)
        flushPendingOpenURLs()
    }


    /// 外部链接 = 活动窗口**新标签**打开（Chrome 语义：不顶掉当前页）。
    /// 活动窗口 manager 未就绪（冷启动早期）→ 留在缓冲等重试。
    private func flushPendingOpenURLs() {
        guard !pendingOpenURLs.isEmpty else { return }
        guard let tm = TabSessionCoordinator.shared.activeTabManager else {
            schedulePendingURLRetry()
            return
        }
        let app = AppState.live
        for url in pendingOpenURLs {
            tm.addTab(
                url: url.absoluteString,
                javaScriptEnabled: app?.settings.isJavaScriptEnabled ?? true,
                contentBlocker: app?.contentBlocker,
                videoAdBlocker: app?.videoAdBlocker,
                autoPlayPolicy: app?.settings.autoPlayPolicy ?? .requireUserAction
            )
        }
        Log.app.info("opened \(self.pendingOpenURLs.count, privacy: .public) external url(s) in tabs")
        pendingOpenURLs.removeAll()
    }

    /// 冷启动重试：窗口/会话恢复完成前 manager 可能不存在——0.2/0.6/1.5s
    /// 三跳兜底，缓冲空则 no-op（幂等）。
    private func schedulePendingURLRetry() {
        for delay in [0.2, 0.6, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushPendingOpenURLs()
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 浏览器标准入口：**kAEGetURL（'GURL'/'GURL'）** 是系统发给默认
        // 浏览器的打开链接事件（其他 app 调 NSWorkspace.open(url) 即此路；
        // Chrome/Firefox 都注册它）。kAEOpenURLs 路径由 application(_:open:)
        // 兜底（open 命令的多 URL 形态）。在 willFinish 阶段注册——早于
        // SwiftUI 装配，事件不漏。
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kAEGetURL), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor?, withReplyEvent reply: NSAppleEventDescriptor?) {
        guard let raw = event?.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else {
            Log.app.error("GURL event without a usable http(s) url")
            return
        }
        Log.app.info("GURL open: \(raw, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        pendingOpenURLs.append(url)
        flushPendingOpenURLs()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("launch phase: didFinishLaunching +\(Int(Date().timeIntervalSince(DesireApp.launchStart) * 1000), privacy: .public)ms")
        installSignalHandlers()
        noticeAbnormalPreviousExit()
        // 冷启动带 URL 启动（默认浏览器点链接拉起 app）：窗口装配晚于
        // didFinishLaunching，走重试 flush。
        schedulePendingURLRetry()
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

    /// 崩溃恢复提示（0.6.2）：启动时读上一次的干净退出标志——为 false 且
    /// 存在即上次异常退出（崩溃/强杀）。标签与会话由既有恢复链路还原，这里
    /// 只补一句知情提示；被打断的回合在对应会话顶部有「继续」入口
    /// （turnActive 检查点）。automation 模式跳过弹窗（E2E 友好），只记日志。
    private func noticeAbnormalPreviousExit() {
        let key = "app.cleanExit"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key) as? Bool
        defaults.set(false, forKey: key)
        guard previous == false else { return }  // 首次启动（无标志）不算异常
        Log.app.info("previous run did not exit cleanly — sessions restored, interrupted turns offer resume")
        guard !CommandLine.arguments.contains("--automation") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))  // 等窗口/恢复装配完
            let alert = NSAlert()
            alert.messageText = "上次没有正常退出"
            alert.informativeText = "标签与会话已尽量恢复。Agent 会话里被中断的回合，\n会在该会话顶部给出「继续」入口。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UserDefaults.standard.set(true, forKey: "app.cleanExit")
        // BUG-K diagnostics: the process occasionally hangs inside exit()
        // after termination is approved. Log everything still alive at the
        // moment we hand control back to AppKit, so a stuck run can be
        // matched against this inventory. Synchronous with a bounded wait —
        // a fire-and-forget Task loses the race against process exit.
        ShutdownDiagnostics.capture(reason: "applicationShouldTerminate")
        TabSessionCoordinator.shared.prepareForTermination()
        ShutdownDiagnostics.capture(reason: "after session flush")
        // 云同步退出前补推：有未上推的本地变更时延后终止，SyncStore 保证 5 秒内
        // 回调（期间 .terminateLater 挂起）；无脏域照常立即退出。
        if let syncStore = AppState.live?.syncStore, syncStore.needsQuitFlush {
            syncStore.flushOnQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
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
