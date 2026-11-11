import AppKit
import CoreGraphics
import Foundation

/// 多窗口 Agent 工具（v0.8.52 批 3）：listWindows 增强、focusWindow、
/// moveTabToWindow。`window` 参数支持 session UUID 前缀 / `session-<uuid>` /
/// agent 会话短 id（与既有 navigate/switchTab/readTab 的 window 参数兼容）。
extension BrowserToolProvider {

    /// 窗口整理（v0.8.52 批 3）：mergeAll / dedupe / onlyHost / splitBySite。
    /// 标签总数 > 60 时转 Jobs 台账（进度 = 已处理标签数）。
    func organizeWindowsTool(_ args: [String: Any]) async -> String {
        let modeRaw = (args["mode"] as? String ?? "").lowercased()
        let mode: WindowOrganizer.Mode
        switch modeRaw {
        case "mergeall": mode = .mergeAll
        case "dedupe": mode = .dedupe
        case "onlyhost":
            guard let host = args["host"] as? String, !host.isEmpty else {
                return Self.fail("host required for onlyHost")
            }
            mode = .onlyHost(host)
        case "splitbysite": mode = .splitBySite
        default:
            return Self.fail("mode must be mergeAll | dedupe | onlyHost | splitBySite")
        }
        guard let source = (args["window"] as? String).flatMap({ TabWindowMove.resolve($0) })
                ?? surface?.tabManager else {
            return Self.fail("no source window")
        }
        let opener: (() async -> TabManager?)? = mode == .splitBySite
            ? { [weak self] in await self?.openWindowForOrganize() }
            : nil
        let totalTabs = TabSessionCoordinator.shared.liveManagers()
            .reduce(0) { $0 + $1.tabs.count }
        if totalTabs > 60 {
            let job = JobStore.shared.start(
                title: String(localized: "Organize windows"),
                kind: .other,
                detail: "\(modeRaw) · \(totalTabs) tab(s)",
                source: "windowOrganizer")
            Task { @MainActor in
                let result = await WindowOrganizer.organize(
                    mode: mode, source: source, opener: opener) { done, total in
                        JobStore.shared.update(job, detail: "\(done)/\(total)",
                                               progress: Double(done) / Double(max(1, total)))
                    }
                switch result {
                case .success(let summary):
                    let text = Self.summaryText(mode: modeRaw, summary: summary)
                    JobStore.shared.finish(job, state: .done, detail: text, receipt: text)
                    AgentScheduler.shared.deliveryTarget?.appendExternalNote(
                        "Window organize finished: \(text)")
                    ProactiveNotificationStore.shared.deliver(
                        title: String(localized: "Window organize finished"),
                        body: text, tier: .routine)
                case .failure(let failure):
                    JobStore.shared.finish(job, state: .failed, error: failure.message)
                }
            }
            return "Window organize (\(modeRaw)) started as job \(job.uuidString) over \(totalTabs) tab(s); check backgroundTaskStatus."
        }
        switch await WindowOrganizer.organize(mode: mode, source: source, opener: opener) {
        case .failure(let failure):
            return Self.fail(failure.message)
        case .success(let summary):
            return Self.summaryText(mode: modeRaw, summary: summary)
        }
    }

    private static func summaryText(mode: String, summary: WindowOrganizer.Summary) -> String {
        var text = "Window organize (\(mode)): moved \(summary.moved), closed \(summary.closed)"
        if summary.windowsOpened > 0 { text += ", opened \(summary.windowsOpened) window(s)" }
        if !summary.detail.isEmpty { text += " — " + summary.detail.joined(separator: "; ") }
        return text
    }

    /// splitBySite 用：开一扇新窗口并等它注册（与 newWindow 工具同路径；
    /// 需要 owner 会话——桥在无会话时不可用）。
    func openWindowForOrganize() async -> TabManager? {
        guard let owner = ownerSession,
              let entryID = AgentScheduler.shared.liveSessions()
                  .first(where: { $0.store === owner })?.id.uuidString else { return nil }
        NSApp.activate(ignoringOtherApps: true)
        let before = Set(TabSessionCoordinator.shared.liveManagers().map(ObjectIdentifier.init))
        NotificationCenter.default.post(name: .desireOpenNewWindow, object: nil,
                                        userInfo: ["session": entryID])
        for _ in 0..<26 {
            try? await Task.sleep(for: .milliseconds(150))
            if let fresh = TabSessionCoordinator.shared.liveManagers()
                .first(where: { !before.contains(ObjectIdentifier($0)) }) {
                return fresh
            }
        }
        return nil
    }

    /// 列出所有**用户浏览器窗口**（不只是绑定了 Agent 会话的那些）。
    func listBrowserWindows() -> String {
        let managers = TabSessionCoordinator.shared.liveManagers().filter {
            WindowRoleRegistry.shared.role(for: $0.sessionKey) == .user
        }
        guard !managers.isEmpty else { return "No browser windows" }
        let own = surface?.tabManager
        let lines = managers.map { manager -> String in
            let window = WindowSurfaceRegistry.shared.window(for: manager.sessionKey)
            let active = window?.isKeyWindow == true ? ", active" : ""
            let frame = window.map {
                "\(Int($0.frame.width))x\(Int($0.frame.height)) at (\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)))"
            } ?? "no frame"
            let ownMark = manager === own ? " (your window)" : ""
            return "[\(TabWindowMove.identifier(manager))] \(TabWindowMove.displayTitle(manager))"
                + " — \(manager.tabs.count) tab(s)\(active), \(frame)\(ownMark)"
        }
        return "Browser windows (\(managers.count)) — pass the bracketed id as `window`:\n"
            + lines.joined(separator: "\n")
    }

    func focusWindowTool(_ args: [String: Any]) -> String {
        guard let manager = TabWindowMove.resolve(args["window"] as? String) else {
            return Self.fail("unknown window — use listWindows to get an id")
        }
        TabWindowMove.focus(manager)
        return "Focused window [\(TabWindowMove.identifier(manager))] — "
            + "\(manager.tabs.count) tab(s): \(TabWindowMove.displayTitle(manager))"
    }

    func moveTabToWindowTool(_ args: [String: Any]) -> String {
        guard let targetArg = args["window"] as? String, !targetArg.isEmpty,
              let target = TabWindowMove.resolve(targetArg) else {
            return Self.fail("window required (target window id from listWindows)")
        }
        let source = (args["from"] as? String).flatMap { TabWindowMove.resolve($0) }
            ?? surface?.tabManager
        guard let source else { return Self.fail("no source window") }
        guard source !== target else { return Self.fail("source and target are the same window") }

        let tab: Tab?
        if let idText = args["tabId"] as? String, let uuid = UUID(uuidString: idText) {
            tab = source.tabs.first { $0.id == uuid }
        } else if let title = args["tabTitle"] as? String, !title.isEmpty {
            let needle = title.lowercased()
            tab = source.tabs.first { $0.displayTitle.lowercased().contains(needle) }
                ?? source.tabs.first { $0.urlString.lowercased().contains(needle) }
        } else {
            let index = (args["index"] as? Int) ?? source.selectedIndex
            tab = source.tabs.indices.contains(index) ? source.tabs[index] : nil
        }
        guard let tab else { return Self.fail("no matching tab in the source window") }

        let targetIndex = args["targetIndex"] as? Int
        guard TabWindowMove.move(tab, from: source, to: target, index: targetIndex) else {
            return Self.fail("move failed")
        }
        return "Moved \"\(tab.displayTitle)\" from [\(TabWindowMove.identifier(source))] "
            + "to [\(TabWindowMove.identifier(target))] — target now \(target.tabs.count) tab(s)."
    }
}
