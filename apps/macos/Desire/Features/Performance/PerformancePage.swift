import AppKit
import SwiftUI

/// 性能面板（v0.8.84 批 4 第 9 件）：`desire://performance` 内置页。
/// 所有数字与桥 `/diag/performance` 同源（PerformanceSnapshot 聚合）——
/// 禁止在视图里另算一套。按钮动作 = 释放内存 / 清快照（走 Doctor 修复链）。
struct PerformancePage: View {
    @State private var snapshot: PerformanceSnapshot?
    @State private var fixNote: String?
    @Environment(\.appAccent) private var appAccent: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let s = snapshot {
                    tabsCard(s)
                    launchCard(s)
                    guardCard(s)
                    hostsCard(s)
                    actionsRow(s)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                if let note = fixNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .task { reload() }
    }

    private func reload() {
        Task {
            let s = await PerformanceSnapshot.collect()
            await MainActor.run { self.snapshot = s }
        }
    }

    private func card(_ title: String, icon: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appAccent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            rows()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func tabsCard(_ s: PerformanceSnapshot) -> some View {
        card("Tabs", icon: "rectangle.stack") {
            Text("\(s.tabCount) tabs · \(s.suspendedCount) suspended · \(s.notLoadedCount) not loaded · \(s.liveTabCount) live")
                .font(.system(size: 11))
            Text("Background DOM-node total: \(s.backgroundNodeTotal)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(s.heaviestTabs, id: \.self) { row in
                Text(row)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
            }
        }
    }

    private func launchCard(_ s: PerformanceSnapshot) -> some View {
        card("Launch", icon: "clock.badge.checkmark") {
            Text("First window: \(s.firstWindowMs)ms · audit: \(s.auditTotalMs)ms / \(s.auditBudgetMs)ms budget\(s.auditOverBudget ? " — OVER" : "")")
                .font(.system(size: 11))
                .foregroundStyle(s.auditOverBudget ? Color.orange : Color.primary)
            ForEach(s.launchStages, id: \.self) { stage in
                Text(stage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func guardCard(_ s: PerformanceSnapshot) -> some View {
        card("Guards & background", icon: "shield.lefthalf.filled") {
            Text("Before-unload guard: \(s.navGuardSkipped) skipped (zero-JS) / \(s.navGuardProbes) probed")
                .font(.system(size: 11))
            Text("Lazy WebView creations: \(s.lazyCreated) (unexpected: \(s.lazyUnexpected))")
                .font(.system(size: 11))
            Text("Plugin background hosts: \(s.pluginHosts) · Memory governor: \(s.memoryBudget == 0 ? "off" : "\(s.memoryBudget) nodes")")
                .font(.system(size: 11))
            Text("Resource load: \(s.resourceLoad) · Downloads concurrency: \(s.downloadConcurrency)")
                .font(.system(size: 11))
        }
    }

    private func hostsCard(_ s: PerformanceSnapshot) -> some View {
        card("Metrics", icon: "chart.bar.xaxis") {
            Text("DevTools buffers: \(s.devConsole) console / \(s.devNetwork) network entries")
                .font(.system(size: 11))
            Text("Main process footprint: \(s.footprint)")
                .font(.system(size: 11))
        }
    }

    private func actionsRow(_ s: PerformanceSnapshot) -> some View {
        HStack {
            Button("Release Memory") {
                Task {
                    let note = await AgentDoctor.applyFix(.releaseMemory)
                    await MainActor.run { fixNote = note }
                    reload()
                }
            }
            .buttonStyle(.bordered)
            Spacer()
            Button("Refresh") { reload() }
                .buttonStyle(.bordered)
        }
    }
}

/// 性能面板与桥 `/diag/performance` 共用的聚合快照（同一份数据源）。
struct PerformanceSnapshot {
    var tabCount = 0
    var suspendedCount = 0
    var notLoadedCount = 0
    var liveTabCount = 0
    var backgroundNodeTotal = 0
    var heaviestTabs: [String] = []
    var firstWindowMs = 0
    var auditTotalMs = 0
    var auditBudgetMs = 0
    var auditOverBudget = false
    var launchStages: [String] = []
    var navGuardProbes = 0
    var navGuardSkipped = 0
    var lazyCreated = 0
    var lazyUnexpected = 0
    var pluginHosts = 0
    var memoryBudget = 0
    var resourceLoad = "normal"
    var downloadConcurrency = 0
    var devConsole = 0
    var devNetwork = 0
    var footprint = "-"

    @MainActor
    static func collect() -> PerformanceSnapshot {
        var s = PerformanceSnapshot()
        let managers = TabSessionCoordinator.shared.liveManagers()
        let allTabs = managers.flatMap { $0.tabs }
        s.tabCount = allTabs.count
        s.suspendedCount = allTabs.filter(\.isSuspended).count
        s.notLoadedCount = allTabs.filter { !$0.isSuspended && !$0.browser.hasLiveWebView }.count
        s.liveTabCount = allTabs.filter { !$0.isSuspended && $0.browser.hasLiveWebView }.count
        let liveBackground = allTabs.filter {
            !$0.isSuspended && $0.browser.hasLiveWebView && $0.id != managers.first?.selectedTab?.id
        }
        s.backgroundNodeTotal = liveBackground.reduce(0) { $0 + max(0, $1.browser.lastDomNodeCount) }
        s.heaviestTabs = liveBackground
            .sorted { $0.browser.lastDomNodeCount > $1.browser.lastDomNodeCount }
            .prefix(5)
            .map { "\($0.displayTitle) — \($0.browser.lastDomNodeCount) nodes" }

        let startup = startupInfo()
        s.firstWindowMs = startup.firstWindowMs
        s.auditTotalMs = startup.auditTotalMs
        s.auditBudgetMs = startup.auditBudgetMs
        s.auditOverBudget = startup.overBudget
        s.launchStages = startup.stages

        s.navGuardProbes = BrowserState.unloadProbesRun
        s.navGuardSkipped = BrowserState.unloadProbesSkipped
        s.lazyCreated = BrowserState.lazyWebViewCreations
        s.lazyUnexpected = BrowserState.unexpectedLazyWebViewCreations
        s.pluginHosts = PluginBackgroundRuntime.hostCount
        s.memoryBudget = AppPrefs.defaults.integer(forKey: "tabMemoryBudgetNodes")

        let conditions = ResourceGovernor.Conditions(
            memoryPressure: TabManager.mainMemoryPressureActive,
            thermalRaw: ProcessInfo.processInfo.thermalState.rawValue,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        let load = ResourceGovernor.load(conditions)
        s.resourceLoad = load.rawValue
        s.downloadConcurrency = ResourceGovernor.concurrency(
            currentMax: 4, load: load)

        s.devConsole = AppState.live?.devToolsStore.consoleMessages.count ?? 0
        s.devNetwork = AppState.live?.devToolsStore.networkRequests.count ?? 0
        s.footprint = ByteCountFormatter.string(
            fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        return s
    }

    /// 桥字典（`/diag/performance`）：与页面同一份 collect()。
    func bridgeDictionary() -> [String: Any] {
        ["ok": true,
         "tabs": tabCount, "suspended": suspendedCount,
         "notLoaded": notLoadedCount, "live": liveTabCount,
         "backgroundNodeTotal": backgroundNodeTotal,
         "heaviestTabs": heaviestTabs,
         "firstWindowMs": firstWindowMs,
         "auditTotalMs": auditTotalMs, "auditBudgetMs": auditBudgetMs,
         "auditOverBudget": auditOverBudget,
         "launchStages": launchStages,
         "navGuardProbes": navGuardProbes, "navGuardSkipped": navGuardSkipped,
         "lazyCreated": lazyCreated, "lazyUnexpected": lazyUnexpected,
         "pluginHosts": pluginHosts,
         "memoryBudget": memoryBudget,
         "resourceLoad": resourceLoad,
         "downloadConcurrency": downloadConcurrency,
         "devConsole": devConsole, "devNetwork": devNetwork]
    }

    @MainActor
    private static func startupInfo() -> (firstWindowMs: Int, auditTotalMs: Int,
                                           auditBudgetMs: Int, overBudget: Bool,
                                           stages: [String]) {
        let first = StartupMetric.firstWindowMs ?? 0
        let audit = LaunchAudit.snapshot()
        let steps = (audit["steps"] as? [[String: Any]]) ?? []
        return (first,
                (audit["totalMs"] as? Int) ?? 0,
                (audit["budgetMs"] as? Int) ?? 0,
                (audit["overBudget"] as? Bool) ?? false,
                steps.map { "\($0["name"] ?? "?"): \($0["ms"] ?? 0)ms" })
    }
}
