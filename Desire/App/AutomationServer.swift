import AppKit
import Foundation
import Network
import os
import WebKit

/// Localhost-only automation bridge for external test drivers (curl).
///
/// Gated behind the `--automation` launch argument — never enabled by
/// default. Binds 127.0.0.1:8799 only; every handler runs on the main
/// actor against the ACTIVE window's TabManager
/// (TabSessionCoordinator.shared).
///
/// Endpoints (JSON in / JSON out):
///   GET  /state              → {tabs:[{index,title,url,incognito}], selected, agentBusy}
///   POST /navigate           {"url":"https://…","index":0?}   → {ok}
///   POST /back               {"index":0?}                     → {ok}
///   POST /forward            {"index":0?}                     → {ok}
///   POST /reload             {"index":0?}                     → {ok}
///   POST /new-tab            {"url":"…"?,"incognito":false?}  → {index}
///   POST /close-tab          {"index":0?}                     → {ok}
///   POST /switch-tab         {"index":0}                      → {ok}
///   GET  /page/text?index=0  → {text} (visible text, ≤20k chars)
///   GET  /page/url?index=0   → {url,title}
///   GET  /page/timing?index=0 → {ttfb,domContentLoaded,load,transferBytes,protocol}
///   GET  /screenshot         → {path} PNG of the selected tab (≤1280w)
///   GET  /history?count=10   → {entries:[{title,url}]}
///   GET  /bookmarks          → {entries:[{title,url}]}
///   GET  /downloads          → {downloads:[{id,file,state,paused,bytes,total,private}]}
///   POST /downloads/pause    {"id"?:uuid}  (first in-progress if omitted) → {ok,id}
///   POST /downloads/resume   {"id"?:uuid}  (first paused if omitted)      → {ok,id}
///   GET  /beforeunload?index=0 → {pending,message?}   (form-protection prompt)
///   POST /beforeunload/resolve {"leave":true,"index":0?} → {ok}
///   POST /execute            {"js":"…","index":0?} → {result} (page JS, for
///                              synthetic-event tests like middle click)
///   POST /panel              {"name":"downloads","show":true?} → {ok,visible}
///                              (show omitted → toggle)
///   GET  /panel/snapshot?name=downloads → {path} PNG rendered in-process
///                              (works even when the display is shielded)
///   GET  /agent/messages     → {messages:[{role,content…}],busy}
///   POST /agent/send         {"text":"…"}                     → {ok}
@MainActor
final class AutomationServer {
    static let shared = AutomationServer()

    private var listener: NWListener?
    private static let port: UInt16 = 8799

    private init() {}

    /// Call once at app startup — no-op unless `--automation` was passed.
    func startIfRequested() {
        guard CommandLine.arguments.contains("--automation"), listener == nil else { return }
        start()
    }

    private func start() {
        let params = NWParameters.tcp
        // Fast relaunches (pkill → open) hit TIME_WAIT on the port;
        // without reuse the listener silently fails and the bridge dies.
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: Self.port)!
        )
        guard let listener = try? NWListener(using: params) else {
            Log.agent.error("automation server: port \(Self.port) unavailable")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handle(connection)
            }
        }
        listener.start(queue: .main)
        Log.agent.info("automation server ready on 127.0.0.1:\(Self.port)")
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                let response = await self.route(request)
                let body = response.data(using: .utf8) ?? Data()
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: head.data(using: .utf8)! + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    // MARK: - Routing

    private func route(_ request: String) async -> String {
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return Self.error("empty request") }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return Self.error("bad request line") }
        let method = String(parts[0])
        let target = String(parts[1])

        let pathComponents = target.split(separator: "?", maxSplits: 2)
        let path = String(pathComponents[0])
        var query: [String: String] = [:]
        if pathComponents.count > 1 {
            for pair in pathComponents[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 2)
                guard kv.count == 2 else { continue }
                query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }

        var body: [String: Any] = [:]
        if let bodyStart = request.range(of: "\r\n\r\n"),
           let data = request[bodyStart.upperBound...].data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            body = parsed
        }

        do {
            switch (method, path) {
            case ("GET", "/state"):
                return try Self.json(Self.appState())
            case ("POST", "/navigate"):
                return try await Self.json(Self.navigate(Self.string(body, "url"), index: Self.index(body)))
            case ("POST", "/back"):
                return try await Self.json(Self.goBack(index: Self.index(body)))
            case ("POST", "/forward"):
                return try await Self.json(Self.goForward(index: Self.index(body)))
            case ("POST", "/reload"):
                return try await Self.json(Self.reload(index: Self.index(body)))
            case ("POST", "/new-tab"):
                return try await Self.json(Self.newTab(
                    url: Self.string(body, "url"),
                    incognito: body["incognito"] as? Bool ?? false
                ))
            case ("POST", "/close-tab"):
                return try await Self.json(Self.closeTab(index: Self.index(body)))
            case ("POST", "/switch-tab"):
                return try await Self.json(Self.switchTab(index: Self.index(body) ?? 0))
            case ("GET", "/page/text"):
                return try await Self.json(Self.pageText(index: Self.index(query)))
            case ("GET", "/page/timing"):
                guard let tab = Self.shared.resolveIndex(Self.index(query)) else {
                    return Self.error("no such tab")
                }
                let timingJS = """
(function(){
    var n = performance.getEntriesByType('navigation')[0];
    if (!n) return JSON.stringify({error: 'no timing entry'});
    return JSON.stringify({
        ttfb: Math.round(n.responseStart),
        domContentLoaded: Math.round(n.domContentLoadedEventEnd),
        load: Math.round(n.loadEventEnd),
        transferBytes: n.transferSize,
        protocol: n.nextHopProtocol
    });
})()
"""
                let raw: String = await withCheckedContinuation { continuation in
                    tab.browser.webView.evaluateJavaScript(timingJS) { result, _ in
                        continuation.resume(returning: (result as? String) ?? "{}")
                    }
                }
                let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                return try Self.json(parsed ?? ["error": "parse failed"])
            case ("GET", "/page/url"):
                return try await Self.json(Self.pageMeta(index: Self.index(query)))
            case ("GET", "/screenshot"):
                return try await Self.json(Self.screenshot())
            case ("GET", "/history"):
                return try Self.json(Self.history(count: Int(query["count"] ?? "10") ?? 10))
            case ("GET", "/spawn-test"):
                // Direct spawn probe — proves the (removed) sandbox really
                // lets the app run system binaries, no LLM involved.
                let out = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    Task.detached {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                        p.arguments = ["-c", "print('spawn-ok')"]
                        let pipe = Pipe()
                        p.standardOutput = pipe
                        do {
                            try p.run()
                            let data = pipe.fileHandleForReading.readDataToEndOfFile()
                            continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                        } catch {
                            continuation.resume(returning: "SPAWN FAILED: \(error.localizedDescription)")
                        }
                    }
                }
                return try Self.json(["spawn": out.trimmingCharacters(in: .whitespacesAndNewlines)])
            case ("POST", "/responsive"):
                guard let tab = try Self.shared.resolveIndex(Self.index(body)) else {
                    return Self.error("no such tab")
                }
                let enabled = body["enabled"] as? Bool ?? true
                if let presetName = Self.string(body, "preset"),
                   let preset = devicePresets.first(where: { $0.name == presetName }) {
                    tab.responsiveConfig.selectedPresetID = preset.id
                    tab.responsiveConfig.customWidth = preset.width
                    tab.responsiveConfig.customHeight = preset.height
                }
                tab.responsiveConfig.isEnabled = enabled   // onChange → Applier
                return try Self.json(["ok": true, "size": tab.responsiveConfig.effectiveSize])
            case ("GET", "/approvals"):
                return try Self.json(Self.pendingApproval())
            case ("GET", "/beforeunload"):
                return try Self.json(Self.beforeUnloadState(index: Self.index(query)))
            case ("POST", "/beforeunload/resolve"):
                return try Self.json(Self.resolveBeforeUnload(
                    index: Self.index(body),
                    leave: body["leave"] as? Bool ?? true
                ))
            case ("POST", "/approvals/resolve"):
                return try Self.json(Self.resolvePendingApproval(
                    Self.string(body, "decision") ?? ""
                ))
            case ("GET", "/settings"):
                let st = Settings()
                return try Self.json([
                    "searchEngine": st.searchEngine.rawValue,
                    "httpsUpgradeEnabled": st.httpsUpgradeEnabled,
                ])
            case ("GET", "/mcp"):
                let store = MCPStore.shared
                let servers = store.servers.map { server -> [String: Any] in
                    [
                        "name": server.name,
                        "url": server.url,
                        "enabled": server.isEnabled,
                        "status": store.statuses[server.id] ?? "—",
                        "tools": store.toolNames(for: server.id),
                    ]
                }
                return try Self.json(["servers": servers, "tools": store.toolDefs.map(\.function.name)])
            case ("GET", "/downloads"):
                return try Self.json(Self.downloads())
            case ("POST", "/downloads/pause"):
                return try Self.json(Self.pauseDownload(Self.string(body, "id")))
            case ("POST", "/downloads/resume"):
                return try Self.json(Self.resumeDownload(Self.string(body, "id")))
            case ("POST", "/execute"):
                return try await Self.json(Self.execute(Self.string(body, "js") ?? "", index: Self.index(body)))
            case ("POST", "/panel"):
                return try Self.json(Self.panel(
                    name: Self.string(body, "name") ?? "",
                    show: body["show"] as? Bool
                ))
            case ("GET", "/panel/snapshot"):
                return try Self.json(Self.panelSnapshot(name: query["name"] ?? "downloads"))
            case ("GET", "/bookmarks"):
                return try Self.json(Self.bookmarks())
            case ("GET", "/agent/messages"):
                return try Self.json(Self.agentMessages())
            case ("POST", "/agent/send"):
                return try Self.json(Self.agentSend(Self.string(body, "text")))
            default:
                return Self.error("unknown route \(method) \(path)")
            }
        } catch {
            return Self.error(error.localizedDescription)
        }
    }

    private static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func error(_ message: String) -> String {
        (try? json(["error": message])) ?? "{\"error\":\"?\"}"
    }

    private static func string(_ dict: [String: Any], _ key: String) -> String? {
        (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Accessors

    private var tabManager: TabManager? {
        get throws { TabSessionCoordinator.shared.activeTabManager }
    }

    private func resolveIndex(_ index: Int?) -> Tab? {
        guard let tm = try? tabManager else { return nil }
        if let index {
            return tm.tabs.indices.contains(index) ? tm.tabs[index] : nil
        }
        return tm.selectedTab
    }

    private static func index(_ body: [String: Any]) -> Int? {
        body["index"] as? Int
    }

    private static func index(_ query: [String: String]) -> Int? {
        query["index"].flatMap(Int.init)
    }

    // MARK: - Endpoint impls

    private static func appState() throws -> [String: Any] {
        let tm = try shared.tabManager
        let tabs: [[String: Any]] = (tm?.tabs ?? []).enumerated().map { i, tab in
            [
                "index": i,
                "title": tab.browser.pageTitle,
                "url": tab.browser.webView.url?.absoluteString ?? tab.urlString,
                "incognito": tab.isIncognito,
                "selected": tm?.selectedIndex == i,
            ]
        }
        return [
            "tabs": tabs,
            "selected": tm?.selectedIndex ?? -1,
            "agentBusy": AgentScheduler.shared.deliveryTarget?.isProcessing ?? false,
        ]
    }

    private static func navigate(_ rawURL: String?, index: Int?) async throws -> [String: Any] {
        guard let rawURL, !rawURL.isEmpty else { return ["error": "missing url"] }
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        let destination = URLResolution.resolve(rawURL, settings: Settings())
        let finalURL: String
        switch destination {
        case .url(let resolved): finalURL = resolved
        case .search(let query, let engine):
            finalURL = URLResolution.searchURL(query: query, target: engine)?.absoluteString ?? rawURL
        case nil:
            return ["error": "unresolvable input"]
        }
        guard let url = URL(string: finalURL) else { return ["error": "bad url"] }
        tab.isOnNewTabPage = false
        tab.urlString = finalURL
        tab.browser.webView.load(URLRequest(url: url))
        return ["ok": true, "navigatedTo": finalURL]
    }

    private static func goBack(index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard tab.browser.webView.canGoBack else { return ["error": "cannot go back"] }
        tab.browser.webView.goBack()
        return ["ok": true]
    }

    private static func goForward(index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard tab.browser.webView.canGoForward else { return ["error": "cannot go forward"] }
        tab.browser.webView.goForward()
        return ["ok": true]
    }

    private static func reload(index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        tab.browser.webView.reload()
        return ["ok": true]
    }

    private static func newTab(url: String?, incognito: Bool) async throws -> [String: Any] {
        let tm = try shared.tabManager
        guard let tm else { return ["error": "no tab manager"] }
        let before = tm.tabs.count
        tm.addTab(url: url, incognito: incognito)
        return ["ok": true, "index": before, "count": tm.tabs.count]
    }

    private static func closeTab(index: Int?) async throws -> [String: Any] {
        let tm = try shared.tabManager
        guard let tm else { return ["error": "no tab manager"] }
        let target = index ?? tm.selectedIndex
        tm.closeTab(at: target)
        return ["ok": true, "count": tm.tabs.count]
    }

    private static func switchTab(index: Int) async throws -> [String: Any] {
        let tm = try shared.tabManager
        guard let tm else { return ["error": "no tab manager"] }
        guard tm.tabs.indices.contains(index) else { return ["error": "index out of range"] }
        tm.selectTab(at: index)
        return ["ok": true, "selected": index]
    }

    private static func pageText(index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        let text: String = await withCheckedContinuation { continuation in
            tab.browser.webView.evaluateJavaScript(
                "(document.body && document.body.innerText || '').substring(0, 20000)"
            ) { result, _ in
                continuation.resume(returning: (result as? String) ?? "")
            }
        }
        return ["text": text]
    }

    private static func pageMeta(index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        return [
            "url": tab.browser.webView.url?.absoluteString ?? tab.urlString,
            "title": tab.browser.webView.title ?? tab.browser.pageTitle,
            "isLoading": tab.isLoading,
            "error": tab.browser.lastError?.localizedDescription,
        ]
    }

    /// PNG snapshot of the selected tab's webview, written next to the
    /// project so external drivers can read it.
    private static func screenshot() async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(nil) else { return ["error": "no such tab"] }
        let image: NSImage? = await withCheckedContinuation { continuation in
            tab.browser.webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return ["error": "snapshot failed"]
        }
        let path = NSHomeDirectory() + "/desire_automation.png"
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
    }

    private static func history(count: Int) throws -> [String: Any] {
        // Fresh instance = read-only view of the persisted state; no shared
        // mutable state with the UI's own store instance.
        let entries = HistoryStore().entries.prefix(count).map { ["title": $0.title, "url": $0.url] }
        return ["entries": Array(entries)]
    }

    private static func bookmarks() throws -> [String: Any] {
        let entries = BookmarkStore().leafEntries.map { ["title": $0.title, "url": $0.url] }
        return ["entries": Array(entries)]
    }

    private static func downloads() throws -> [String: Any] {
        guard let store = DownloadStore.live else { return ["error": "store not ready"] }
        let items = store.downloads.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "file": item.filename,
                "state": item.state.rawValue,
                "paused": item.isPaused,
                "bytes": item.downloadedBytes,
                "total": item.totalBytes,
                "private": item.isPrivate,
            ]
        }
        return ["downloads": Array(items)]
    }

    /// Drives the pause→resume path so external tests can reproduce the
    /// instant-resume race (resume pressed before the checkpoint data lands).
    private static func pauseDownload(_ id: String?) throws -> [String: Any] {
        guard let store = DownloadStore.live else { return ["error": "store not ready"] }
        guard let uuid = id.flatMap(UUID.init(uuidString:)) ?? store.downloads.first(where: { $0.state == .inProgress })?.id else {
            return ["error": "no such download"]
        }
        store.pause(id: uuid)
        return ["ok": true, "id": uuid.uuidString, "paused": true]
    }

    private static func resumeDownload(_ id: String?) throws -> [String: Any] {
        guard let store = DownloadStore.live else { return ["error": "store not ready"] }
        guard let uuid = id.flatMap(UUID.init(uuidString:)) ?? store.downloads.first(where: { $0.isPaused })?.id else {
            return ["error": "no paused download"]
        }
        store.resume(id: uuid)
        return ["ok": true, "id": uuid.uuidString, "paused": false]
    }

    /// Runs JS in the page and returns the result. Synthetic-event driven
    /// tests (middle click, keyboard) go through here.
    private static func execute(_ js: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        let result: Any? = await withCheckedContinuation { continuation in
            tab.browser.webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: result)
            }
        }
        return ["result": result as Any ?? NSNull()]
    }

    /// Opens/closes app-shell panels so external drivers can screenshot
    /// SwiftUI chrome that /screenshot (webview-only) cannot see.
    private static func panel(name: String, show: Bool?) throws -> [String: Any] {
        guard name == "downloads" else { return ["error": "unknown panel"] }
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let visible = show ?? !app.showDownloadsPanel
        app.showDownloadsPanel = visible
        return ["ok": true, "visible": visible]
    }

    /// Renders an open panel's content view to PNG **in-process** via
    /// `dataWithPDF` — unlike `screencapture -l` this works while the
    /// display is occluded, on another Space, or capture-shielded.
    private static func panelSnapshot(name: String) throws -> [String: Any] {
        guard name == "downloads" else { return ["error": "unknown panel"] }
        // SwiftUI presents .popover content in an NSPopover-backed window.
        let popoverWindow = NSApp.windows.first { window in
            let kind = String(describing: type(of: window))
            if kind.contains("Popover") { return true }
            // Fallback: any small visible window (the main window is
            // screen-sized, chrome strips are tiny-height).
            return window.isVisible
                && window.frame.width > 200 && window.frame.width < 600
                && window.frame.height > 200
        }
        guard let window = popoverWindow, let view = window.contentView else {
            return ["error": "downloads popover not open"]
        }
        // NSHostingView is layer-backed and draws black via dataWithPDF;
        // cacheDisplay goes through the view's own drawing path.
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return ["error": "bitmap alloc failed"]
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return ["error": "encode failed"]
        }
        let path = NSHomeDirectory() + "/desire_panel.png"
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
    }

    private static func pendingApproval() throws -> [String: Any] {
        guard let session = AgentScheduler.shared.deliveryTarget else {
            return ["error": "no live agent session"]
        }
        guard let approval = session.pendingApproval else {
            return ["pending": false]
        }
        return [
            "pending": true,
            "tool": approval.toolCall.function.name,
            "arguments": approval.argumentsSummary,
            "risk": approval.risk.displayName,
        ]
    }

    /// beforeunload 表单保护的程序化决策入口：GET /beforeunload 查询挂起
    /// 状态，POST /beforeunload/resolve {"leave":true|false} 替用户点击。
    private static func beforeUnloadState(index: Int?) throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let pending = tab.browser.pendingBeforeUnload else { return ["pending": false] }
        return ["pending": true, "message": pending.message]
    }

    private static func resolveBeforeUnload(index: Int?, leave: Bool) throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let pending = tab.browser.pendingBeforeUnload else { return ["error": "no pending before-unload"] }
        pending.respond(leave: leave)
        return ["ok": true, "leave": leave]
    }

    /// Resolves a pending approval: decision ∈ allow_once | always_allow | deny.
    /// Lets external test drivers exercise the dangerous-tool path end to
    /// end without a human click.
    private static func resolvePendingApproval(_ decision: String) throws -> [String: Any] {
        guard let session = AgentScheduler.shared.deliveryTarget, session.pendingApproval != nil else {
            return ["error": "no pending approval"]
        }
        let outcome: ApprovalDecision
        switch decision {
        case "allow_once": outcome = .allowOnce
        case "always_allow": outcome = .alwaysAllow
        case "deny": outcome = .deny
        default: return ["error": "decision must be allow_once | always_allow | deny"]
        }
        session.resolveApproval(outcome)
        return ["ok": true, "resolved": decision]
    }

    private static func agentMessages() throws -> [String: Any] {
        guard let session = AgentScheduler.shared.deliveryTarget else {
            return ["error": "no live agent session"]
        }
        let messages = session.messages.suffix(12).map { message -> [String: Any] in
            var item: [String: Any] = ["role": message.role.rawValue]
            if let content = message.content { item["content"] = String(content.prefix(2000)) }
            if let calls = message.toolCalls { item["toolCalls"] = calls.map(\.function.name) }
            return item
        }
        return ["messages": Array(messages), "busy": session.isProcessing]
    }

    private static func agentSend(_ text: String?) throws -> [String: Any] {
        guard let text, !text.isEmpty else { return ["error": "missing text"] }
        guard let session = AgentScheduler.shared.deliveryTarget else {
            return ["error": "no live agent session"]
        }
        session.sendMessage(text)
        return ["ok": true]
    }
}
