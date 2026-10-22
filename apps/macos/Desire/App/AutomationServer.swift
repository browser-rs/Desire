import AppKit
import Foundation
import SwiftUI
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
/// Self-describing: `GET /` returns the full endpoint catalog (with params
/// and examples) plus the SSE event list — machines learn the driver there.
///
/// Auth (optional): launch with `--automation-token <token>`; every request
/// must then carry `Authorization: Bearer <token>`. Default stays open on
/// localhost.
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
///   POST /devtools/eval      {"js":"…"}     → console REPL (executes + logs)
///   POST /devtools/inspect   {"selector":"…"} → fill the Element tab
///   GET  /devtools           → console/network/element counters + last rows
///   GET  /devtools/application → cookies + localStorage/sessionStorage of the tab
///   POST /devtools/edit      {"selector":"…","style":{…},"attributes":{…}}
///   POST /devtools/application/delete {"kind":"cookie|localStorage|sessionStorage","key":"…"}
///   POST /devtools/application/set    {"kind":"localStorage|sessionStorage|extension",
///                                       "key":"…","value":"…","ext":uuid?}
///   GET  /rules              → ad-rule sources (builtin/local/remote) + dir
///   POST /rules/refresh      → re-read local overrides + fetch remote bundle
///   GET  /diag/geometry?index=0 → web view frame/superview/subview tree +
///                              every window's frame, style mask & screen
///   GET  /bookmarks          → {entries:[{title,url}]}
///   GET  /downloads          → {downloads:[{id,file,state,paused,bytes,total,private}]}
///   POST /downloads/pause    {"id"?:uuid}  (first in-progress if omitted) → {ok,id}
///   POST /downloads/resume   {"id"?:uuid}  (first paused if omitted)      → {ok,id}
///   GET  /beforeunload?index=0 → {pending,message?}   (form-protection prompt)
///   POST /beforeunload/resolve {"leave":true,"index":0?} → {ok}
///   GET  /shortcuts         → {shortcuts:[{id,key,modifierFlags,customized}],menu}
///   POST /shortcuts/update  {"id":"newTab","key":"k","modifierFlags":cmd} →
///                             {ok} | {error:"conflict",conflicts:[ids]}
///                             (menu picks it up on next launch)
///   POST /execute            {"js":"…","index":0?} → {result} (page JS, for
///                              synthetic-event tests like middle click)
///   POST /panel              {"name":"downloads","show":true?} → {ok,visible}
///                              (show omitted → toggle)
///   GET  /panel/snapshot?name=downloads → {path} PNG rendered in-process
///                              (works even when the display is shielded)
///   GET  /agent/messages     → {messages:[{role,content…}],busy}
///   POST /agent/send         {"text":"…"}                     → {ok}
///   GET  /agent/tasks        → {tasks:[{name,prompt,enabled,recurrence,lastResult}]}
///   POST /agent/tasks/create {"name","prompt",minutes | hour+minute} → {ok}
///   POST /agent/tasks/remove {"name"} → {ok}
///   POST /agent/tasks/fire   {"name"} — deliver immediately (E2E) → {ok}
///   POST /approvals/simulate — arm a REAL pending approval (no model turn;
///                              resolve via /approvals/resolve) → {ok}
@MainActor
final class AutomationServer {
    static let shared = AutomationServer()

    private var listener: NWListener?
    nonisolated static let port: UInt16 = 8799
    /// "127.0.0.1:8799" 文案与判定统一从这里取（ARCH-7：字面量曾散布 4 处）。
    /// nonisolated：非隔离上下文（索引构建/Extract 判定）也要取。
    nonisolated static let hostPort = "127.0.0.1:\(port)"
    nonisolated static let baseURL = "http://\(hostPort)"

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
        // 专用串行队列，**不再挂 .main**：主 actor 被打瘫（ObjC 异常穿 async 帧
        // 的僵尸态发生过两次）时，桥必须还能收发——回调各自 Task { @MainActor }
        // 跳回主 actor，Network.framework 本身线程安全（CONC-1）。
        listener.start(queue: Self.bridgeQueue)
        Log.agent.info("automation server ready on 127.0.0.1:\(Self.port)")
    }

    // MARK: - Connection handling

    /// When the app was launched with `--automation-token <token>`, every
    /// request (including /events) must carry `Authorization: Bearer <token>`.
    /// Default: no token → localhost open, behavior unchanged.
    private static let requiredToken: String? = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--automation-token"), i + 1 < args.count {
            return args[i + 1]
        }
        if let i = args.firstIndex(where: { $0.hasPrefix("--automation-token=") }) {
            return String(args[i].dropFirst("--automation-token=".count))
        }
        return nil
    }()

    private static func isAuthorized(_ request: String) -> Bool {
        guard let requiredToken else { return true }
        guard let header = request
            .split(separator: "\r\n", omittingEmptySubsequences: false)
            .first(where: { $0.lowercased().hasPrefix("authorization:") }) else {
            return false
        }
        let value = header.split(separator: ":", maxSplits: 1).last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return BearerAuthentication.matches(header: value, token: requiredToken)
    }

    /// 请求头取值（大小写不敏感；唯一命中）。
    private static func header(_ request: String, _ name: String) -> String? {
        request
            .split(separator: "\r\n", omittingEmptySubsequences: false)
            .first { $0.lowercased().hasPrefix("\(name.lowercased()):") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces)
    }

    /// DNS-rebinding / 浏览器跨站防御（0.7.4 安全轮）。两条硬闸：
    /// ① **Host 必须是本机**（127.0.0.1 / localhost，端口可带）——攻击者把
    ///    自家域名 A 记录改指 127.0.0.1 后，浏览器视其为同源，页面不仅能
    ///    打到桥、还能**读到响应**（GET /page/text 之类变成任意内幕读取）。
    /// ② **带 Origin 头的请求必须源自本机**——浏览器对跨站 fetch/表单 POST
    ///    总会带 Origin（no-cors 也带，副作用照样发生：恶意页面能给
    ///    /agent/send 发指令）；curl / CI / MCP 客户端不带 Origin，不受影响。
    ///    `null`（file:// 源）同样拒绝——桥没有来自本地文件的合法调用方。
    private static func passesOriginGuard(_ request: String) -> Bool {
        // Host 头无 scheme；Origin 头是 scheme://host[:port]——先剥 scheme 再取 host。
        func localHost(_ value: String, stripScheme: Bool) -> Bool {
            var v = value
            if stripScheme, let range = v.range(of: "://") { v = String(v[range.upperBound...]) }
            let host = v.split(separator: ":").first.map(String.init)?.lowercased() ?? v.lowercased()
            return host == "127.0.0.1" || host == "localhost"
        }
        // 请求行不带 Host 的客户端（极老式 HTTP/1.0 工具）按本机对待——
        // HTTP/1.1 浏览器必带 Host，rebinding 防线不受影响。
        if let host = header(request, "Host"), !localHost(host, stripScheme: false) {
            Log.agent.fault("automation bridge rejected: non-local Host '\(host, privacy: .public)'")
            return false
        }
        if let origin = header(request, "Origin"),
           origin == "null" || !localHost(origin, stripScheme: true) {
            Log.agent.fault("automation bridge rejected: non-local Origin '\(origin, privacy: .public)'")
            return false
        }
        return true
    }

    /// 请求是否已收完整：头齐全 + body 字节数 ≥ Content-Length。
    /// **必须按字节找头尾**——`String(data:)` 会在多字节字符被分段处直接失败，
    /// 反过来把"不完整"误判成"不该等"。
    private nonisolated static func requestIsComplete(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        let separator = Array("\r\n\r\n".utf8)
        guard bytes.count >= separator.count else { return false }
        var headEnd: Int?
        for i in 0...(bytes.count - separator.count) {
            if bytes[i] == separator[0], Array(bytes[i..<(i + separator.count)]) == separator {
                headEnd = i
                break
            }
        }
        guard let headEnd else { return false }
        var contentLength = 0
        let head = String(decoding: data.prefix(headEnd), as: UTF8.self)
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                contentLength = n
            }
        }
        return bytes.count - (headEnd + separator.count) >= contentLength
    }

    /// 桥的网络事件队列（串行）。见 start() 里的注释：绝不挂 .main。
    private nonisolated static let bridgeQueue = DispatchQueue(label: "me.siwi.Desire.automation-bridge")

    private func handle(_ connection: NWConnection) {
        connection.start(queue: Self.bridgeQueue)
        receiveRequest(connection, accumulated: Data())
    }

    /// **一次 `receive()` 不保证收完整请求**——TCP 想什么时候分段就什么时候分段
    /// （CI 虚机的网络栈上尤其常见）。曾经单个 receive 直接进 `route`：请求被
    /// 截断在头部的那些回合，`body` 解析成空字典，`/agent/send` 之类全数报
    /// "missing text"，而且完全随机、本地几乎复现不出来（2026-09-24，eval 在
    /// CI 上 E2/E3 稳定失败才现形）。现在按 Content-Length 攒齐再路由。
    private nonisolated func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            let buffer = accumulated + data
            guard Self.requestIsComplete(buffer) else {
                if isComplete {
                    // 对端已关连接但请求仍不完整——没有可路由的东西了。
                    connection.cancel()
                    return
                }
                self.receiveRequest(connection, accumulated: buffer)
                return
            }
            guard let request = String(data: buffer, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                guard Self.passesOriginGuard(request) else {
                    let body = Self.error("forbidden — bridge only accepts local Host/Origin (DNS-rebinding & cross-site guard)")
                    let head = "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: head.data(using: .utf8)! + body.data(using: .utf8)!, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                guard Self.isAuthorized(request) else {
                    let body = Self.error("unauthorized — missing or wrong bearer token")
                    let head = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: head.data(using: .utf8)! + body.data(using: .utf8)!, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                // X-Desire-Window: the caller (e.g. the MCP server with a
                // window-bound session) targets a specific window — switch
                // the active TabManager for this request, restore after.
                let windowHeader = request
                    .split(separator: "\r\n", omittingEmptySubsequences: false)
                    .first { $0.lowercased().hasPrefix("x-desire-window:") }
                    .map { $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "" }
                    .flatMap { UUID(uuidString: String($0)) }
                if let windowHeader,
                   let target = TabSessionCoordinator.shared.manager(forSession: windowHeader),
                   let previous = TabSessionCoordinator.shared.activeTabManager {
                    TabSessionCoordinator.shared.setActive(target)
                    defer { TabSessionCoordinator.shared.setActive(previous) }
                    let response = await self.route(request)
                    let body = response.data(using: .utf8) ?? Data()
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: head.data(using: .utf8)! + body, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                // SSE stream: long-lived, not routed through the one-shot
                // request/response path.
                if request.hasPrefix("GET /events") {
                    self.startEventStream(connection)
                    return
                }
                let response = await self.route(request)
                let body = response.data(using: .utf8) ?? Data()
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: head.data(using: .utf8)! + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    // MARK: - Event stream (SSE)

    private var eventStreamConnections: [UUID: NWConnection] = [:]
    private var eventStreamHeartbeats: [UUID: Task<Void, Never>] = [:]

    /// Continues draining an SSE connection (called on the main actor).
    private func drainEvents(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { _, _, _, error in
            Task { @MainActor in
                if error == nil {
                    self.drainEvents(connection, id: id)
                } else {
                    BridgeEventBus.shared.unsubscribe(id)
                    self.eventStreamConnections.removeValue(forKey: id)
                    self.eventStreamHeartbeats.removeValue(forKey: id)?.cancel()
                    connection.cancel()
                }
            }
        }
    }

    /// `GET /events` — upgrade the connection to an SSE stream fed by
    /// BridgeEventBus. Kept open until the client goes away; every inbound
    /// byte from the client is drained so we notice disconnects.
    private func startEventStream(_ connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: head.data(using: .utf8)!, completion: .contentProcessed { _ in })
        let id = BridgeEventBus.shared.subscribe { [weak connection] frame in
            connection?.send(content: frame.data(using: .utf8)!, completion: .contentProcessed { error in
                if let error {
                    Log.agent.error("bridge events: SSE send failed: \(error.localizedDescription, privacy: .public)")
                }
            })
        }
        eventStreamConnections[id] = connection

        // 15 s keep-alive comment: dead sockets surface as send errors and
        // get cleaned up instead of lingering in the sinks dict.
        let heartbeat = Task { [weak connection] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                connection?.send(content: Data(": keep-alive\n\n".utf8), completion: .contentProcessed { error in
                    if error != nil { connection?.cancel() }
                })
            }
        }
        eventStreamHeartbeats[id] = heartbeat

        func drain() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { _, _, _, error in
                Task { @MainActor in
                    if error == nil {
                        self.drainEvents(connection, id: id) // keep-alives land here; events keep flowing
                    } else {
                        BridgeEventBus.shared.unsubscribe(id)
                        self.eventStreamConnections.removeValue(forKey: id)
                        self.eventStreamHeartbeats.removeValue(forKey: id)?.cancel()
                        connection.cancel()
                    }
                }
            }
        }
        drain()
        Log.agent.info("bridge events: stream opened (\(self.eventStreamConnections.count, privacy: .public) live)")
    }

    // MARK: - Self description

    /// Self-describing endpoint catalog served at `GET /`. Lets any AI or
    /// script learn the driver without external docs. KEEP IN SYNC with the
    /// switch below — new endpoints get an entry here.
    private static let endpointCatalog: [[String: Any]] = { () -> [[String: Any]] in
        var eps: [[String: Any]] = []
        func ep(_ method: String, _ path: String, _ description: String, params: [String] = [], example: String) {
            eps.append(["method": method, "path": path, "description": description,
                        "params": params,
                        "example": "curl -s \(method == "GET" ? "" : "-X \(method) ")\(baseURL)\(path) → \(example)"])
        }
        // Browsing
        ep("GET", "/state", "All tabs (index/title/url/incognito/selected/suspended/domNodes) + selected + window flags", example: #"{"tabs":[…],"selected":0}"#)
        ep("POST", "/navigate", "Navigate a tab", params: ["url:string (required)", "index?:int"], example: #"-d '{"url":"https://example.com"}'"#)
        ep("POST", "/video-speed", "Set video playback rate for the selected tab (persisted per page via video-speed.js)", params: ["rate:number (0.25-3)", "window?:uuid"], example: #"-d '{"rate":1.5}'"#)
        ep("POST", "/back", "Go back", params: ["index?:int"], example: "-d '{}'")
        ep("POST", "/forward", "Go forward", params: ["index?:int"], example: "-d '{}'")
        ep("POST", "/reload", "Reload", params: ["index?:int"], example: "-d '{}'")
        ep("POST", "/new-tab", "Open a tab (optionally incognito / in a named container)", params: ["url?:string", "incognito?:bool", "container?:string"], example: #"-d '{"url":"https://example.com","incognito":true}'"#)
        ep("POST", "/close-tab", "Close tab (last tab closes its window)", params: ["index?:int"], example: "-d '{\"index\":1}'")
        ep("POST", "/switch-tab", "Select tab", params: ["index:int"], example: "-d '{\"index\":0}'")
        ep("GET", "/page/text", "Visible page text (≤20k chars)", params: ["index?:int"], example: "…/page/text?index=0")
        ep("GET", "/page/url", "url/title/isLoading/zoom/error", params: ["index?:int"], example: "…/page/url")
        ep("GET", "/page/timing", "Navigation timing (ttfb/load/protocol)", params: ["index?:int"], example: "…/page/timing")
        ep("GET", "/find", "Find in page: matchFound + count + first-match snippet", params: ["q:string", "index?:int", "caseSensitive?:0|1"], example: "…/find?q=hello")
        ep("GET", "/suggest", "Address-bar suggestions (local rows)", params: ["q:string"], example: "…/suggest?q=git")
        ep("GET", "/conversations/search", "Search saved agent conversations (same code path as the searchConversations tool)", params: ["q:string", "limit?:int"], example: "…/conversations/search?q=github")
        ep("POST", "/conversations/delete", "Delete conversations (cleanup after tests, batch)", params: ["ids:[uuid]", "id?:uuid"], example: #"-d '{"ids":["…"]}'"#)
        ep("GET", "/agent/trace", "Conversation trace as JSONL — one line per turn (goal, steps with per-tool ms, answer, critique, verification, feedback)", params: ["conversation?:uuid (default: live)", "limit?:int"], example: "…/agent/trace?limit=3")
        ep("GET", "/agent/stats", "Token usage statistics derived from saved conversations (same code as the panel's Usage page)", params: ["days?:int (include the daily series)"], example: "…/agent/stats?days=30")
        ep("POST", "/execute", "Run JS in the page, return result", params: ["js:string", "index?:int", "world?:string(main|extension)"], example: #"-d '{"js":"document.title"}'"#)
        ep("GET", "/screenshot", "PNG of a tab (default selected). inline=1 → base64 in response; otherwise writes ~/desire_automation.png", params: ["index?:int", "inline?:bool"], example: "…/screenshot?index=0&inline=1")
        // Panels & chrome
        ep("POST", "/panel", "Open/close an app panel (downloads, devtools+tab)", params: ["name:string", "show?:bool", "tab?:string"], example: #"-d '{"name":"devtools","tab":"network"}'"#)
        ep("GET", "/windows", "On-screen Desire windows (number for `screencapture -l<number>`, title, frame, isKey)", example: "…/windows")
        ep("POST", "/app/quit", "Graceful quit (same path as Cmd+Q: terminate → flush → exit)", example: "-d '{}'")
        ep("GET", "/conversations", "Newest agent conversations (id/title/messages/firstMessage) — pair with /conversations/delete for cleanup", params: ["limit?:int (default 20)"], example: "…/conversations?limit=5")
        ep("GET", "/media/batch/log", "Full per-batch download log (create/resolve/download/merge/pause/fail, newest last)", params: ["id:string (batch uuid)", "tail?:int (default all)"], example: "…/media/batch/log?id=…")
        ep("POST", "/media/batch/manage", "Manage a batch directly (no agent round-trip): pause/resume/cancel/skip; batchId/itemId accept 8-char short ids", params: ["action:pause|resume|cancel|skip|remove", "batchId:string", "itemId?:string"], example: #"-d '{"action":"pause","batchId":"76a91071"}'"#)
        ep("GET", "/panel/snapshot", "In-process PNG of an open panel (capture-shield safe)", params: ["name:string (downloads|devtools|agentstats|inbox|workspaces|whiteboard|syncchecklist|…)", "tab?:string (devtools)", "w?/h?:number"], example: "…/panel/snapshot?name=devtools&tab=network")
        ep("POST", "/command", "Drive any BrowserCommand (menu actions)", params: ["name:string (zoomIn/newTab/bookmarkPage/toggleReader/addSelectionToWhiteboard/…)", "index?:int (selectTab)"], example: #"-d '{"name":"newTab"}'"#)
        // Downloads
        ep("GET", "/downloads", "Rows: id/file/state/paused/bytes/total/private", example: "…/downloads")
        ep("POST", "/downloads/remove", "Remove a row from the list (file on disk untouched)", params: ["id:uuid"], example: #"-d '{"id":"…"}'"#)
        ep("POST", "/downloads/pause", "Pause", params: ["id?:uuid"], example: "-d '{}'")
        ep("POST", "/downloads/resume", "Resume", params: ["id?:uuid"], example: "-d '{}'")
        ep("GET", "/downloads/scheduled", "Scheduled downloads (id/url/filename/startAt)", example: "…/downloads/scheduled")
        ep("POST", "/downloads/schedule", "Schedule a download: startAt (unix seconds) or inSeconds", params: ["url:string", "startAt?:double", "inSeconds?:double", "filename?:string"], example: "-d '{\"url\":\"https://a.b/f.zip\",\"inSeconds\":5}'")
        ep("POST", "/downloads/scheduled/cancel", "Cancel a scheduled download", params: ["id:uuid"], example: "-d '{\"id\":\"…\"}'")
        // Data stores
        ep("GET", "/history", "History, newest first", params: ["count?:int"], example: "…/history?count=10")
        ep("GET", "/history?grouped=1", "History aggregated by domain (panel site-grouping equivalent, same pure logic)", params: ["grouped:1"], example: "…/history?grouped=1")
        ep("POST", "/history/remove", "Remove one history entry by id (test hygiene)", params: ["id:uuid"], example: #"-d '{"id":"<uuid>"}'"#)
        ep("GET", "/history/content", "Search locally indexed page text (opt-in). Returns url/title/snippet/score", params: ["q:string", "limit?:int"], example: "…/history/content?q=rust")
        ep("GET", "/history/content/stats", "Page-text index state (enabled/count)", example: "…/history/content/stats")
        ep("POST", "/history/content", "Enable/disable page-text indexing", params: ["enabled:bool"], example: "-d '{\"enabled\":true}'")
        ep("POST", "/history/content/clear", "Delete the local page-text index", example: "-d '{}'")
        ep("GET", "/whatsnew", "What's New state for the current build (hasUnseen/presented/version)", example: "…/whatsnew")
        ep("POST", "/whatsnew/show", "Show the What's New sheet (automation; normal launches auto-show once)", example: "-d '{}'")
        ep("POST", "/whatsnew/dismiss", "Mark What's New as seen for this build", example: "-d '{}'")
        ep("POST", "/whatsnew/reset", "Forget the seen marker (testing/replay)", example: "-d '{}'")
        ep("GET", "/diag/geometry", "Web view + window frames (fullscreen debugging)", params: ["index?:int"], example: "…/diag/geometry")
        ep("GET", "/diag/browser", "Browser diagnostics: content-process crash count + recent crashes", example: "…/diag/browser")
        ep("GET", "/activity", "Activity center: downloads/batch media/exports/scheduled runs/agent sessions/crew", example: "…/activity")
        ep("POST", "/diag/export", "Export a diagnostics zip (MetricKit + crash counters + last 30 min OSLog)", example: "-d '{}'")
        ep("POST", "/workflow/start", "Start recording a web workflow on the active tab", example: "-d '{}'")
        ep("POST", "/workflow/stop", "Stop recording and save the workflow", params: ["name:string"], example: #"-d '{"name":"login flow"}'"#)
        ep("GET", "/workflow/list", "Saved web workflows (host/steps/sensitive count)", example: "…/workflow/list")
        ep("POST", "/workflow/run", "Replay a workflow on the active tab (sensitive values via values map)", params: ["id?/name?", "values?:{stepId:value}"], example: #"-d '{"name":"login flow","values":{"<step-uuid>":"…"}}'"#)
        ep("POST", "/workflow/delete", "Delete a saved workflow", params: ["id:string"], example: #"-d '{"id":"<uuid>"}'"#)
        ep("POST", "/workflow/offer", "Toggle 'offer on visit' for a workflow (id or name)", params: ["id?:string", "name?:string", "offer:bool"], example: "-d '{\"name\":\"login flow\",\"offer\":true}'")
        ep("POST", "/workflow/suggestion/dismiss", "Dismiss the current page's workflow suggestion", example: "-d '{}'")
        ep("POST", "/backup/export", "Write a full backup JSON (settings/bookmarks/history/reading list/quick dials/Agent memory; no keys)", params: ["path:string (file or directory)"], example: #"-d '{"path":"/tmp/desire-backup.json"}'"#)
        ep("POST", "/backup/import", "Restore a backup: mode=merge (add missing) | replace (overwrite); optional domains filter", params: ["path:string", "mode?:merge|replace", "domains?:[settings|bookmarks|history|readingList|quickDials|agentMemory|readerHighlights|workflows]"], example: #"-d '{"path":"/tmp/desire-backup.json","mode":"merge","domains":["bookmarks"]}'"#)
        ep("POST", "/backup/preview", "Preview a backup file: version/date/domain counts (no changes)", params: ["path:string"], example: #"-d '{"path":"/tmp/desire-backup.json"}'"#)
        ep("POST", "/devtools/eval", "Run JS in the console REPL path", params: ["js:string", "index?:int"], example: #"-d '{"js":"document.title"}'"#)
        ep("POST", "/devtools/inspect", "Fill the Element tab from a selector", params: ["selector:string", "index?:int"], example: #"-d '{"selector":"h1"}'"#)
        ep("GET", "/devtools", "DevTools panel state (scoped counters, tab list, totals)", example: "…/devtools")
        ep("GET", "/devtools/har", "HAR 1.2 export of captured network requests (same records as the panel)", params: ["scope?:string(all|current|tab=<uuid>)"], example: "…/devtools/har?scope=all")
        ep("POST", "/devtools/config", "Runtime toggles (console clearing, Application section, tab scope)", params: ["clearConsoleOnNavigate?:bool", "applicationSection?:string", "tabScope?:current|all|<tab uuid>"], example: #"-d '{"tabScope":"all"}'"#)
        ep("POST", "/devtools/preview", "Fetch a page resource via the page (cookies included) and save it as PNG", params: ["url:string", "index?:int"], example: #"-d '{"url":"http://127.0.0.1:8878/pixel.png"}'"#)
        ep("POST", "/devtools/replay", "Re-send a recorded request from the page (same path as the ↻ button)", params: ["url:string", "index?:int"], example: #"-d '{"url":"http://127.0.0.1:8879/api/data"}'"#)
        ep("GET", "/devtools/console/ref", "Expand a console object handle (one level; handles come from console rows)", params: ["ref:string", "index?:int"], example: "…/devtools/console/ref?ref=c1")
        ep("GET", "/devtools/application", "Cookies + web storage of the active tab", params: ["index?:int"], example: "…/devtools/application")
        ep("POST", "/devtools/edit", "Edit inline style/attributes of an element", params: ["selector:string", "style?:json", "attributes?:json"], example: #"-d '{"selector":"h1","style":{"color":"red"}}'"#)
        ep("POST", "/devtools/application/delete", "Delete a cookie/storage/IndexedDB/cache/service worker", params: ["kind:string (cookie|localStorage|sessionStorage|extension|indexedDB|cache|cacheAll|serviceWorker)", "key?:string", "ext?:uuid", "index?:int"], example: #"-d '{"kind":"indexedDB","key":"mydb"}'"#)
        ep("POST", "/devtools/application/set", "Write a cookie / localStorage / sessionStorage / extension key", params: ["kind:string", "key:string", "value:string", "domain?:string (cookies)", "ext?:uuid", "index?:int"], example: #"-d '{"kind":"localStorage","key":"foo","value":"bar"}'"#)
        ep("POST", "/devtools/application/delete", "Delete a cookie/storage/IndexedDB/cache/service worker (cookie 的 key = name@domain，面板行 id 同款)", params: ["kind:string", "key:string", "ext?:uuid", "index?:int"], example: #"-d '{"kind":"cookie","key":"name@domain"}'"#)
        ep("GET", "/rules", "Video ad-rule sources (builtin/local/remote)", example: "…/rules")
        ep("POST", "/rules/refresh", "Reload local rule overrides + fetch remote bundle", example: "-d '{}'")
        ep("GET", "/bookmarks", "Bookmark leaves; ?tree=1 returns the folder tree with ids", example: "…/bookmarks?tree=1")
        ep("POST", "/bookmarks/add", "Add bookmark", params: ["title:string", "url:string"], example: #"-d '{"title":"X","url":"https://a.b"}'"#)
        ep("POST", "/bookmarks/remove", "Remove by URL or id (folder id removes its subtree)", params: ["url?:string", "id?:uuid"], example: "-d '{\"url\":\"https://a.b\"}'")
        ep("POST", "/bookmarks/import", "Import Netscape-format bookmarks (html= or path=); duplicate plan + import; dryRun plans only, strategy=skipDuplicates|keepAll", params: ["html?/path?", "dryRun?", "strategy?"], example: #"-d '{"path":"/tmp/bm.html","dryRun":true}'"#)
        ep("GET", "/bookmarks/health", "Bookmark link check state (running/progress/dead/redirected)", example: "…/bookmarks/health")
        ep("POST", "/bookmarks/health/cleanup", "Remove bookmarked dead links after review (wizard equivalent; tombstones)", params: ["urls:[string]"], example: #"-d '{"urls":["https://dead.example"]}'"#)
        ep("POST", "/bookmarks/health/check", "Start a background bookmark link check (nothing deleted automatically)", params: ["urls?:[string]", "limit?:int"], example: #"-d '{"limit":100}'"#)
        ep("GET", "/reading-list", "Reading list", example: "…/reading-list")
        ep("GET", "/workspaces", "Saved window workspaces (name/tabs/savedAt)", example: "…/workspaces")
        ep("POST", "/workspaces/delete", "Delete a saved workspace by name", params: ["name:string"], example: #"-d '{"name":"…"}'"#)
        ep("GET", "/tab-groups", "Tab groups (name/color/tabCount)", example: "…/tab-groups")
        ep("POST", "/agent/eval-export", "Export 👍-rated turns as eval JSONL (AgentTrace-derived); path = target directory", params: ["path?:string"], example: "-d '{}'")
        ep("GET", "/agent/eval-exports", "Existing eval exports (newest first)", example: "…/agent/eval-exports")
        ep("POST", "/agent/eval-export/delete", "Delete one eval export (only eval-thumbsup-*.jsonl)", params: ["path:string"], example: #"-d '{"path":"/…"}'"#)
        ep("POST", "/agent/eval-fixture/register", "Turn an eval JSONL export into an agent-eval --fixtures JSON (redacted)", params: ["path:string"], example: #"-d '{"path":"/…/eval-thumbsup-….jsonl"}'"#)
        ep("GET", "/agent/eval-fixtures", "Existing eval fixtures (agent-eval --fixtures directory)", example: "…/agent/eval-fixtures")
        ep("POST", "/agent/eval-fixture/delete", "Delete one eval fixture (only fixtures-*.json)", params: ["path:string"], example: #"-d '{"path":"/…"}'"#)
        ep("GET", "/crew", "Tab-crew observation: per-worker state/currentStep/elapsed/toolCalls + tokens", example: "…/crew")
        ep("POST", "/crew", "Crew control: action=clear (dismiss settled strip) | cancel (cancel running workers)", params: ["action"], example: #"-d '{"action":"clear"}'"#)
        ep("POST", "/inbox/dismiss", "Hide inbox items: action=ignore (permanent) | snooze (hours? or until epoch)", params: ["ids:[string]", "action", "hours?/until?"], example: #"-d '{"ids":["…"],"action":"snooze","hours":2}'"#)
        ep("POST", "/inbox/batch", "Batch inbox actions: retry failed scheduled tasks | ignore | snooze", params: ["action: retry|ignore|snooze", "ids:[string]", "hours?/until?"], example: #"-d '{"action":"retry","ids":["run-daily-1800000000"]}'"#)
        ep("POST", "/inbox/restore", "Restore hidden inbox items (ids omitted = all)", params: ["ids?:[string]"], example: "-d '{}'")
        ep("GET", "/inbox", "Inbox: 等你处理 + 变化与结果（与 Agent 窗口收件箱页同源）", example: "…/inbox")
        ep("GET", "/session-archives", "Archived sessions of closed windows (newest first)", example: "…/session-archives")
        ep("POST", "/session-archives/restore", "Restore an archived session into a window (replaces its tabs)", params: ["file:string", "window?:uuid"], example: #"-d '{"file":"archived-…json"}'"#)
        ep("POST", "/session-archives/delete", "Delete an archived session file", params: ["file:string"], example: #"-d '{"file":"archived-…json"}'"#)
        ep("POST", "/tab-groups/delete", "Delete a tab group by name (test cleanup)", params: ["name:string"], example: #"-d '{"name":"…"}'"#)
        ep("POST", "/reading-list/add", "Add item", params: ["title:string", "url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("POST", "/reading-list/remove", "Remove by URL", params: ["url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("POST", "/reading-list/cache", "Cache an item for offline reading (.webarchive; reuses the item's open tab when available)", params: ["url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("POST", "/reading-list/progress", "Set reading progress (0..1) for an item (stamps LWW for sync)", params: ["url:string", "ratio:double"], example: #"-d '{"url":"https://a.b","ratio":0.42}'"#)
        ep("POST", "/reading-list/summarize", "Batch-summarize saved pages in the background (readURL + bypass model call; summaries land on the items)", params: ["limit?:int", "force?:bool", "urls?:[string]"], example: #"-d '{"limit":5}'"#)
        ep("GET", "/system/integrations", "OS integration permission state (reminders / calendar: granted|denied|restricted|notDetermined) — read-only, never prompts", example: "…/system/integrations")
        ep("GET", "/speech", "Text-to-speech state (speaking/paused) — reader TTS, also driven by the readAloud tool", example: "…/speech")
        ep("POST", "/speech/stop", "Stop text-to-speech immediately (automation cleanup)", example: "-d '{}'")
        ep("GET", "/agent/budget", "Conversation token budget (budget/used/state off|within|warning|stopped/stopLevel/percent)", example: "…/agent/budget")
        ep("POST", "/agent/budget", "Set the conversation token budget (0 = off; resets the tier)", params: ["tokens:int"], example: #"-d '{"tokens":50000}'"#)
        ep("GET", "/sync/devices", "Account devices + per-device pull cursors (live fetch from the sync server)", example: "…/sync/devices")
        ep("GET", "/sync/conflicts", "Recent sync conflicts (entries where the server's LWW copy won; decrypted readable labels)", example: "…/sync/conflicts")
        ep("POST", "/sync/conflicts/clear", "Clear the conflict-details ledger", example: "-d '{}'")
        ep("GET", "/sync/status", "Cloud sync state (auth / syncing / lastSyncAt / lastError / per-domain cursors + pending tombstones)", example: "…/sync/status")
        ep("POST", "/sync/now", "Run a full sync cycle (all domains), return resulting status", example: "-d '{}'")
        ep("POST", "/sync/login", "Sign in (then auto-sync at launch + every 5 min)", params: ["username:string", "password:string"], example: #"-d '{"username":"u","password":"p"}'"#)
        ep("POST", "/sync/register", "Create account + sign in", params: ["username:string", "password:string"], example: #"-d '{"username":"u","password":"p"}'"#)
        ep("POST", "/sync/logout", "Sign out on this device (server tokens revoked)", example: "-d '{}'")
        ep("POST", "/sync/server", "Point the sync client at a server base URL (persisted)", params: ["baseURL:string"], example: #"-d '{"baseURL":"http://127.0.0.1:18090"}'"#)
        ep("POST", "/sync/setting", "Write one syncable setting locally (pushed to server on next sync)", params: ["key:string", "string|bool|number:value"], example: #"-d '{"key":"homePage","string":"https://example.com"}'"#)
        ep("POST", "/remote/toggle", "E2E/automation: enable/disable remote control (Mac side)", params: ["enabled:bool"], example: #"-d '{"enabled":true}'"#)
        ep("POST", "/remote/pair", "E2E/automation: start a pairing code on the Mac side", example: "-d '{}'")
        ep("GET", "/remote/sessions-frame", "The remote sessions frame (same builder as the phone's frame; includes per-session unread)", example: "…/remote/sessions-frame")
        ep("POST", "/remote/mark-seen", "Mark a conversation as seen by the phone (same path as the phone's select receipt)", params: ["conversationId:string"], example: #"-d '{"conversationId":"…"}'"#)
        ep("GET", "/remote/board-payload", "The snapshot board payload for a conversation (same builder the remote frame uses)", params: ["conversationId?:string"], example: "…/remote/board-payload")
        ep("POST", "/share-card", "Generate a page share card (first-screen snapshot + title/domain + optional side-model summary) and save it to Downloads", params: ["index?:int (tab; default selected)", "summarize?:bool (default true)"], example: #"-d '{"summarize":false}'"#)
        ep("GET", "/history/archive-search", "Search the full archived browsing history (client-side: pulls the encrypted history domain and decrypts locally; requires sync sign-in)", params: ["q:string", "limit?:int (default 50)"], example: "…/history/archive-search?q=rust")
        ep("GET", "/agent/cost-breakdown", "This conversation's cost broken down by model x category (main/subagent/bypass), plus the AgentUsage total", params: ["window?:string"], example: "…/agent/cost-breakdown")
        ep("GET", "/ai/routing", "Routing state (costAware / providerKind / lockedToCloud / lastProviderUsed)", example: "…/ai/routing")
        ep("POST", "/ai/routing", "Enable/disable cost-aware routing (existing RoutingProvider: simple text turns prefer on-device/Ollama)", params: ["enabled:bool"], example: "-d '{\"enabled\":true}'")
        ep("POST", "/agent/daily-brief", "Run the daily brief now (today's conversations/usage/inbox/memory → session note + routine notification; toBoard=true also puts it on the whiteboard)", params: ["toBoard?:bool"], example: "-d '{}'")
        ep("POST", "/selection/assist", "Run the selection in-place card once (side-model streaming; no conversation messages created)", params: ["text:string", "mode?:auto|explain|translate|dictionary"], example: #"-d '{"text":"serendipity"}'"#)
        ep("GET", "/board/gallery", "Whiteboard template gallery index (community)", params: ["baseURL?:string (default https://desire.mankong.icu/gallery/; E2E uses a fixture)"], example: "…/board/gallery")
        ep("POST", "/board/gallery/import", "Import a community template into the whiteboard", params: ["id:string", "mode?:auto|append|replace (auto = set when empty else append)", "baseURL?:string", "conversationId?:uuid"], example: #"-d '{"id":"swot"}'"#)
        ep("GET", "/remote/status", "E2E/automation: remote state incl. active pairing code + session key (LOCAL DEV BRIDGE ONLY — never expose beyond localhost)", example: "…/remote/status")
        ep("POST", "/sync/domain", "Enable/disable a sync category", params: ["domain:string (bookmarks|quickdials|reading_list|keyboard_shortcuts|settings)", "enabled:bool"], example: #"-d '{"domain":"quickdials","enabled":false}'"#)
        ep("GET", "/search-history", "Recent search queries", params: ["count?:int"], example: "…/search-history?count=5")
        ep("POST", "/search-history/add", "Record a search", params: ["query:string", "engine?:string"], example: #"-d '{"query":"weather"}'"#)
        ep("POST", "/search-history/clear", "Clear search history", example: "-d '{}'")
        ep("GET", "/quickdial", "New-tab quick dial", example: "…/quickdial")
        ep("POST", "/quickdial/add", "Add dial", params: ["title:string", "url:string"], example: #"-d '{"title":"X","url":"https://a.b"}'"#)
        ep("POST", "/quickdial/delete", "Delete by URL", params: ["url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("GET", "/site-settings", "Per-host zoom/darkMode/blockedSelectors", params: ["host:string"], example: "…/site-settings?host=example.com")
        ep("POST", "/site-settings/darkmode", "Set per-host dark mode", params: ["host:string", "enabled:bool"], example: #"-d '{"host":"example.com","enabled":true}'"#)
        ep("POST", "/site-settings/zoom", "Set per-host zoom", params: ["host:string", "zoom:double"], example: #"-d '{"host":"example.com","zoom":1.5}'"#)
        ep("POST", "/site-settings/font", "Per-site fonts: minFontSize (0=off)/fontFamily (''=off)/null=follow default; re-injects immediately", params: ["host", "minFontSize?", "fontFamily?"], example: #"-d '{"host":"a.b","minFontSize":16}'"#)
        ep("POST", "/site-settings/autoplay", "Per-site auto-play override: mode allow|block|follow (follow = global / video-site default). Takes effect on the next webview (new tab).", params: ["host:string", "mode:string"], example: #"-d '{"host":"www.youtube.com","mode":"block"}'"#)
        ep("POST", "/site-settings/clear", "Clear all per-site UI overrides (zoom/dark/auto-play/fonts; blocked rules untouched) and re-apply to the active tab", params: ["host:string"], example: #"-d '{"host":"a.b"}'"#)
        ep("GET", "/agent/weekly-digest", "Weekly report state (enabled/weekday/hour/due/lastDeliveredAt/lastText)", example: "…/agent/weekly-digest")
        ep("POST", "/agent/weekly-digest", "Weekly report actions: run-now (templated digest → session note + routine notification) / run-pipeline (digest → seed weekly board template → append digest block → optional Notes write) / enable / disable", params: ["action", "writeToNotes?:bool (run-pipeline)", "conversationId?:uuid (run-pipeline; default = delivery target)"], example: #"-d '{"action":"run-pipeline"}'"#)
        ep("GET", "/agent/rule-draft", "Derive Output-Rule drafts from a trace turn's failure/slow patterns (templated, no model call)", params: ["conversation?:uuid", "turn?:int (default last)"], example: "…/agent/rule-draft")
        ep("GET", "/agent/find", "Find messages in the live conversation (case-insensitive; content only)", params: ["q:string", "window?:string"], example: "…/agent/find?q=deploy")
        ep("GET", "/memory/conflicts", "Pending memory-conflict reviews (approximate relatedness; queue from auto-extraction)", example: "…/memory/conflicts")
        ep("POST", "/memory/conflicts/resolve", "Resolve a conflict: resolution=keepNew|keepOld|keepBoth|merge; factID (review) or newText (manual)", params: ["factID?/newText?", "relatedIDs:[uuid]", "resolution", "mergedText?"], example: #"-d '{"newText":"…","relatedIDs":["…"],"resolution":"merge"}'"#)
        ep("POST", "/skills/distill", "Distill a SKILL.md draft from the live conversation (one bypass model call); save=true writes it", params: ["save?:bool", "window?:string"], example: #"-d '{"save":true}'"#)
        ep("GET", "/palette", "Command-palette mixed search (commands/tabs/bookmarks/history/conversations, grouped + per-source totals)", params: ["q:string"], example: "…/palette?q=book")
        ep("GET", "/bilingual", "Bilingual reading state for the active tab (on/running/done/total/error)", example: "…/bilingual")
        ep("POST", "/bilingual", "Toggle bilingual reading (AI translations inserted under each paragraph)", params: ["on:bool", "index?:int"], example: #"-d '{"on":true}'"#)
        ep("GET", "/elements", "Element-blocker rules", example: "…/elements")
        ep("POST", "/elements/add", "Hide matching CSS on matching hosts", params: ["selector:string", "pattern:string"], example: #"-d '{"selector":"nav","pattern":"example.com"}'"#)
        ep("POST", "/elements/remove", "Remove rule", params: ["selector:string", "pattern:string"], example: "-d '{…}'")
        ep("POST", "/tabs/pin", "Pin/unpin", params: ["index?:int", "pinned?:bool"], example: #"-d '{"index":0,"pinned":true}'"#)
        ep("GET", "/tabgroups", "Tab groups", example: "…/tabgroups")
        ep("POST", "/tabgroups/create", "Create group (optionally absorb tab)", params: ["name:string", "index?:int"], example: #"-d '{"name":"Work","index":1}'"#)
        ep("POST", "/tabgroups/collapse", "Collapse/expand", params: ["name:string", "collapsed?:bool"], example: "-d '{\"name\":\"Work\"}'")
        ep("POST", "/tabgroups/delete", "Delete group (tabs survive)", params: ["name:string"], example: "-d '{\"name\":\"Work\"}'")
        ep("POST", "/tabgroups/organize", "Group ungrouped tabs of the active window by site (>=3 tabs/site)", example: "-d '{}'")
        ep("POST", "/tabgroups/undo", "Undo the last organize", example: "-d '{}'")
        ep("POST", "/containers/remove", "Remove container by name", params: ["name:string"], example: "-d '{\"name\":\"Shop\"}'")
        ep("GET", "/downloads/dangerous", "Pending dangerous-download confirmation (bar)", example: "…/downloads/dangerous")
        ep("POST", "/downloads/dangerous/resolve", "Resolve the confirmation (allow=true reloads the URL as a download)", params: ["allow:bool"], example: "-d '{\"allow\":true}'")
        ep("GET", "/plugins", "User plugin (userscript) list", example: "…/plugins")
        ep("GET", "/webext/debug", "ExtensionEventHub listener count + tab listener flags", example: "…/webext/debug")
        ep("POST", "/webext/fire", "Manually fire an extension tab event (diagnostics)", params: ["event:string"], example: "-d '{\"event\":\"tabs.onActivated\"}'")
        ep("POST", "/webext/eval", "Run JS in the ISOLATED extension world of the selected tab (sees browser.*; /execute cannot)", params: ["js:string"], example: "-d '{\"js\":\"typeof browser\"}'")
        ep("POST", "/plugins/add", "Create a userscript plugin (runs in the isolated extension world with browser.* API)", params: ["name:string", "js:string", "patterns?:array", "runAt?:string(document_start|document_end|document_idle)", "pinned?:bool", "icon?:string(sf-symbol)", "background?:string(background script source)"], example: "-d '{\"name\":\"t\",\"js\":\"console.log(1)\",\"patterns\":[\"*://127.0.0.1/*\"]}'")
        ep("POST", "/plugins/pin", "Pin/unpin a plugin to the toolbar", params: ["id:string", "pinned:bool"], example: "-d '{\"id\":\"<uuid>\",\"pinned\":true}'")
        ep("POST", "/plugins/bg-eval", "Evaluate JS in a plugin's background webview (debugging/E2E)", params: ["id:string", "js:string"], example: "-d '{\"id\":\"<uuid>\",\"js\":\"window.__bgLog\"}'")
        ep("GET", "/plugins/dnr", "Plugin declarativeNetRequest diagnostics (rule counts per store + dropped rules)", params: ["id:string"], example: "…/plugins/dnr?id=<uuid>")
        ep("POST", "/plugins/install-msex", "Install a .msex package (manifest v3 subset: content_scripts + popup)", params: ["path:string"], example: "-d '{\"path\":\"/tmp/demo.msex\"}'")
        ep("POST", "/plugins/remove", "Remove a plugin", params: ["id:string"], example: "-d '{\"id\":\"<uuid>\"}'")
        ep("GET", "/passwords", "Password metadata + pendingSave (never secrets)", example: "…/passwords")
        ep("POST", "/passwords/add", "Seed a credential (domain/username/password)", params: ["domain:string", "username:string", "password:string"], example: "-d '{\"domain\":\"example.com\",\"username\":\"u\",\"password\":\"p\"}'")
        ep("POST", "/passwords/import", "Import CSV (Chrome format) into the store", params: ["csv:string"], example: "-d '{\"csv\":\"name,url,username,password\\n…\"}'")
        ep("POST", "/passwords/resolve", "Resolve save/update-password prompt", params: ["save:bool"], example: "-d '{\"save\":true}'")
        ep("POST", "/passwords/delete", "Delete credentials for a domain (optional username = one account)", params: ["domain:string", "username?:string"], example: "-d '{\"domain\":\"example.com\",\"username\":\"u\"}'")
        ep("GET", "/import/browsers", "Detected Chrome/Edge/Brave/Arc/Safari profiles with bookmarks/history paths", example: "…/import/browsers")
        ep("POST", "/import/preview", "Preview a browser profile (path = profile folder or data file): bookmark/history counts, settings, warnings", params: ["path:string"], example: "-d '{\"path\":\"/Users/me/Library/Application Support/Google/Chrome/Default\"}'")
        ep("POST", "/import/run", "Import from a browser profile (bookmarks/history/settings booleans, default all). Password import stays CSV-only.", params: ["path:string", "bookmarks?:bool", "history?:bool", "settings?:bool"], example: "-d '{\"path\":\"…/Default\",\"bookmarks\":true,\"history\":true}'")
        ep("GET", "/webapps", "Installed web apps (App Mode) with id/name/url/shareSession", example: "…/webapps")
        ep("POST", "/webapps/add", "Install a URL as a Web App (no window opened via bridge)", params: ["url:string", "name?:string", "shareSession?:bool"], example: "-d '{\"url\":\"https://example.com\",\"name\":\"Example\"}'")
        ep("POST", "/webapps/delete", "Uninstall a Web App by id (clears its isolated data store)", params: ["id:uuid"], example: "-d '{\"id\":\"<uuid>\"}'")
        ep("GET", "/split", "Split-view state (selected + partner tab index)", example: "…/split")
        ep("POST", "/split", "Set the split-view right pane to a tab index", params: ["index:int"], example: "-d '{\"index\":1}'")
        ep("POST", "/split/close", "Leave split view", example: "-d '{}'")
        ep("GET", "/profiles", "Named browsing personas", example: "…/profiles")
        ep("POST", "/profiles/add", "Create profile", params: ["name:string"], example: "-d '{\"name\":\"Work\"}'")
        ep("POST", "/profiles/remove", "Delete profile", params: ["name:string"], example: "-d '{\"name\":\"Work\"}'")
        ep("GET", "/profiles/active", "Active profile data store of this window", example: "…/profiles/active")
        ep("POST", "/profiles/active", "Switch this window's profile (empty = default)", params: ["name:string"], example: "-d '{\"name\":\"Work\"}'")
        ep("GET", "/annotations", "Highlights of a tab's page (Agent/export)", params: ["index?:int"], example: "…/annotations?index=0")
        ep("GET", "/shortcuts", "Shortcut mappings + live NSMenu accelerators", example: "…/shortcuts")
        ep("POST", "/shortcuts/update", "Re-record binding (next launch)", params: ["id:string", "key:string", "modifierFlags:uint"], example: #"-d '{"id":"newTab","key":"k","modifierFlags":1048576}'"#)
        // Agent
        ep("GET", "/ai/profiles", "Model services: endpoint/model/headers/key state + which is active", example: "…/ai/profiles")
        ep("POST", "/ai/profiles", "Create (no id) or update a model service; key supported", params: ["id?:uuid", "name:string", "endpoint:string", "model?:string", "models?:array", "headers?:object", "key?:string"], example: #"-d '{"name":"My gateway","endpoint":"https://host/v1/chat/completions","model":"gpt-4o","key":"sk-…"}'"#)
        ep("POST", "/ai/profiles/activate", "Switch the active model service", params: ["id:uuid"], example: #"-d '{"id":"…"}'"#)
        ep("GET", "/ai/bypass-profile", "Which service runs the quiet bypass calls (title / memory); null = same as the chat", example: "…/ai/bypass-profile")
        ep("POST", "/ai/bypass-profile", "Route bypass calls (title / memory extraction / summaries) to a service — usually a cheaper model; omit id to clear", params: ["id?:uuid"], example: #"-d '{"id":"…"}'"#)
        ep("GET", "/ai/fallback-profile", "Which service takes over when the current one keeps failing on transient errors; null = no failover", example: "…/ai/fallback-profile")
        ep("POST", "/ai/fallback-profile", "Set the failover service (one extra stream attempt after a transient retry fails); omit id to clear", params: ["id?:uuid"], example: #"-d '{"id":"…"}'"#)
        ep("POST", "/ai/model", "Switch the current model (same path as the input-bar menu)", params: ["model:string"], example: #"-d '{"model":"gpt-4o-mini"}'"#)
        ep("POST", "/ai/models/fetch", "Fetch a service's /models list into its model list (same fetcher the UI uses)", params: ["id?:uuid (default: active)"], example: "-d '{}'")
        ep("POST", "/ai/profiles/delete", "Delete a custom model service (built-ins cannot be deleted)", params: ["id:uuid"], example: #"-d '{"id":"…"}'"#)
        ep("GET", "/ai/output-rules", "Output rules (the <output_rules> prompt layer)", example: "…/ai/output-rules")
        ep("POST", "/ai/output-rules/add", "Append one output rule (dedup)", params: ["text:string"], example: #"-d '{"text":"…"}'"#)
        ep("POST", "/ai/output-rules/remove", "Remove one output rule by exact text", params: ["text:string"], example: #"-d '{"text":"…"}'"#)
        ep("GET", "/ai/prices", "Model price table (USD per Mtok) used to turn token usage into cost", example: "…/ai/prices")
        ep("POST", "/ai/prices", "Set/clear model prices; 0 or omitted = unknown (that model shows no money)", params: ["models?:{model:{input,output}}", "remove?:[model]"], example: #"-d '{"models":{"gpt-4o":{"input":2.5,"output":10}}}'"#)
        ep("GET", "/agent/messages", "Live agent conversation + busy (+hasInterruptedTurn: 上回合被中断待继续)", example: "…/agent/messages")
        ep("POST", "/agent/open", "Load a conversation into the live agent panel (crash-recovery: open the interrupted one before /agent/resume)", params: ["conversationId:uuid"], example: #"-d '{"conversationId":"…"}'"#)
        ep("POST", "/agent/feedback", "Rate an assistant message (thumbs up/down); persisted with the conversation", params: ["messageId:string", "vote:up|down|none"], example: #"-d '{"messageId":"…","vote":"up"}'"#)
        ep("GET", "/filters", "Community filter lists state (enabled, lastUpdated, ruleCount, error)", example: "…/filters")
        ep("POST", "/filters/probe", "Convert ABP lines to content-blocker JSON and compile them, reporting per-line errors", params: ["abp:string (one rule per line)", "includeHiding?:bool"], example: #"-d '{"abp":"/web_ads/*$image"}'"#)
        ep("POST", "/filters/refresh", "Re-download + compile filter lists", params: ["id?:string", "force?:bool"], example: "-d '{}'")
        ep("GET", "/ads/rules", "Saved element-block rules (optional host filter)", params: ["host?:string"], example: "…/ads/rules")
        ep("POST", "/ads/rules/clear", "Remove element-block rules (host, or all)", params: ["host?:string"], example: "-d '{}'")
        ep("GET", "/ads/candidates", "Ad-like elements on the tab, with the reason each matched (same scan the agent runs)", params: ["index?:int"], example: "…/ads/candidates")
        ep("POST", "/ads/block", "Hide elements on this host now and on future loads (+ optional request blocks)", params: ["selectors:[string]", "urlPattern?:string", "requests?:[string]", "index?:int"], example: #"-d '{"selectors":["[id=\"banner\"]"]}'"#)
        ep("GET", "/media/exports", "Background media exports (downloadMedia) with state", example: "…/media/exports")
        ep("POST", "/media/exports/cancel", "Cancel a running media export", params: ["id:uuid"], example: #"-d '{"id":"…"}'"#)
        ep("POST", "/media/batch", "Batch video download: mode=page queues every stream sniffed on the tab; mode=list resolves each detail-page URL in a hidden browser (serialized, Cloudflare-aware)", params: ["mode:page|list", "urls?:[string] (mode=list)", "folderName?:string", "index?:int (mode=page)"], example: #"-d '{"mode":"list","urls":["https://…/v1","https://…/v2"],"folderName":"demo"}'"#)
        ep("POST", "/settings/section", "Select the settings window section (automation; also opens the settings window)", params: ["section:string (general|ai|sync|remote|privacy|autofill|keyboardShortcuts|batchDownloads)"], example: #"-d '{"section":"batchDownloads"}'"#)
        ep("GET", "/notifications/policy", "Proactive notification policy (quiet hours / daily routine budget) + digest queue state", example: "…/notifications/policy")
        ep("POST", "/notifications/policy", "Update the notification policy (omit fields to keep)", params: ["quietHoursEnabled?:bool", "quietStart?:HH:mm", "quietEnd?:HH:mm", "dailyRoutineLimit?:int (0 = unlimited)"], example: #"-d '{"quietHoursEnabled":true,"quietStart":"23:00","quietEnd":"08:00"}'"#)
        ep("POST", "/notifications/test", "Push a test notification through the tiering gate (E2E): reports held vs delivered", params: ["tier:routine|urgent", "title?:string", "body?:string"], example: #"-d '{"tier":"routine","title":"T"}'"#)
        ep("POST", "/notifications/flush", "Deliver the held digest now (ignores quiet hours)", example: "-d '{}'")
        ep("GET", "/ads/stats", "Ad-blocking statistics (video-rule events only; see the stats panel)", example: "…/ads/stats")
        ep("POST", "/ads/stats/clear", "Reset ad-blocking statistics", example: "-d '{}'")
        ep("GET", "/media/batch", "Batch download progress (per-item states; needsHuman = waiting for a manual check in the popup window)", params: ["id?:uuid"], example: "…/media/batch")
        ep("POST", "/media/batch/cancel", "Cancel a whole batch", params: ["id:uuid"], example: "-d '{\"id\":\"…\"}'")
        ep("POST", "/media/batch/skip", "Skip one pending/needsHuman item", params: ["id:uuid", "itemId:uuid"], example: "-d '{\"id\":\"…\",\"itemId\":\"…\"}'")
        ep("POST", "/media/batch/retry", "Re-run a finished batch's failed items (list mode re-resolves for fresh signed URLs)", params: ["id:uuid"], example: "-d '{\"id\":\"…\"}'")
        ep("POST", "/media/batch/pause", "Pause a running batch (in-flight items return to pending)", params: ["id:uuid"], example: "-d '{\"id\":\"…\"}'")
        ep("POST", "/media/batch/resume", "Resume a paused batch", params: ["id:uuid"], example: "-d '{\"id\":\"…\"}'")
        ep("POST", "/media/batch/add", "Append tasks to an existing batch (deduped; numbering continues)", params: ["id:uuid", "urls:[string]", "kind?:list|media", "referer?:string"], example: #"-d '{"id":"…","urls":["https://…/v13"]}'"#)
        ep("GET", "/media/batch/config", "Batch download preferences (disk reserve GB / naming / save root)", example: "…/media/batch/config")
        ep("POST", "/media/batch/config", "Set batch preferences; free space below reserveGB suspends the batch until it recovers", params: ["reserveGB?:int (default 5)", "naming?:clean|code|title", "baseDirectory?:string|null"], example: #"-d '{"reserveGB":5}'"#)
        ep("POST", "/agent/directive", "Set/clear the session-scoped temporary instruction (empty text clears)", params: ["text:string"], example: #"-d '{"text":"Answer in English for this conversation"}'"#)
        ep("POST", "/agent/note", "Append a system note to the conversation (not rendered; folded into the system prompt)", params: ["text:string"], example: #"-d '{"text":"Download finished: x.bin"}'"#)
        ep("GET", "/agent/doctor", "Agent self-check report (model endpoint reachability, keys, MCP, ffmpeg, hooks, skills, notifications, heartbeat)", example: "…/agent/doctor")
        ep("GET", "/containers", "Tab containers (includes ephemeral agent-isolation containers while in use)", example: "…/containers")
        ep("GET", "/agent/modes", "Agent modes (standard/research/writing) + per-window bindings", example: "…/agent/modes")
        ep("GET", "/agent/roster", "Agent persona roster (personas + per-window bindings)", example: "…/agent/roster")
        ep("POST", "/agent/roster", "Manage the persona roster: action=add (name, tone) | remove (id) | bind (window, persona? — omit to unbind) | bind-model (window, profile? — omit to follow global)", params: ["action:add|remove|bind|bind-model", "name?:string", "tone?:string", "id?:uuid", "window?:uuid", "persona?:uuid", "profile?:uuid"], example: #"-d '{"action":"bind","window":"…","persona":"…"}'"#)
        ep("GET", "/agent/guard", "AI action review (guard) toggle state", example: "…/agent/guard")
        ep("POST", "/agent/guard", "Enable/disable the guard review that checks auto-edit actions against the user's rules before they run silently", params: ["enabled:bool"], example: #"-d '{"enabled":true}'"#)
        ep("POST", "/agent/guard/check", "Run one guard review offline (E2E/debug; no gate, no turn): classify a planned action against given rules", params: ["tool:string", "arguments?:object|string", "identity?:string", "rules?:[string]", "directive?:string"], example: #"-d '{"tool":"deleteFile","arguments":{"path":"~/notes.txt"},"identity":"Always confirm before deleting anything."}'"#)
        ep("GET", "/agent/heartbeat", "Heartbeat check-in state (enabled / interval / checklist / last beat)", example: "…/agent/heartbeat")
        ep("POST", "/agent/heartbeat", "Configure the heartbeat check-in (omit fields to keep)", params: ["enabled?:bool", "intervalMinutes?:int (15|30|60|120|240)", "checklist?:string"], example: #"-d '{"enabled":true,"intervalMinutes":60}'"#)
        ep("POST", "/agent/heartbeat/fire", "Run one heartbeat beat now (E2E; bypasses interval and quiet hours): model decides silent vs ping", example: "-d '{}'")
        ep("GET", "/agent/hooks", "Lifecycle hooks state (enabled + per-file list)", example: "…/agent/hooks")
        ep("POST", "/agent/hooks", "Enable/disable hooks globally", params: ["enabled:bool"], example: #"-d '{"enabled":true}'"#)
        ep("POST", "/agent/hooks/reload", "Rescan the hooks folder and rebuild the JS contexts", example: "-d '{}'")
        ep("POST", "/agent/new", "Start a fresh agent conversation (old conversation file untouched)", example: "-d '{}'")
        ep("POST", "/update/install", "Self-update: download the latest release zip, verify SHA256, replace /Applications bundle, relaunch (only when installed in /Applications)", example: "-d '{}'")
        ep("POST", "/agent/resume", "Re-run the trailing unanswered user prompt (mid-turn crash recovery)", example: "-d '{}'")
        ep("POST", "/agent/cancel", "Stop the running turn (same as Esc in the panel)", example: "-d '{}'")
        ep("GET", "/agent/prompt", "Pending user question (agent askUser / batch low-disk-space ask)", example: "…/agent/prompt")
        ep("POST", "/agent/prompt/answer", "Answer the pending question (free text; the asker interprets it)", params: ["text:string"], example: #"-d '{"text":"继续"}'"#)
        ep("POST", "/agent/send", "Prompt the live agent session", params: ["text:string", "recordHistory?:bool (default false)"], example: #"-d '{"text":"summarize this page"}'"#)
        ep("POST", "/agent/resume", "Checkpoint resume: continue a turn that was interrupted by a crash/force-quit (action=resume) or clear the marker (action=discard)", params: ["action:resume|discard", "window?:string"], example: #"-d '{"action":"resume"}'"#)
        ep("GET", "/agent/tasks", "Scheduled agent tasks", example: "…/agent/tasks")
        ep("POST", "/agent/handoff", "Hand the current delivery session's conversation to another window (target takes over; source returns to a fresh conversation)", params: ["window:string (live session id from GET /agent/windows)"], example: #"-d '{"window":"…"}'"#)
        ep("GET", "/agent/crew", "Tab Crew status (per-subtask progress + reports)", example: "…/agent/crew")
        ep("POST", "/agent/crew/cancel", "Cancel the whole crew (or one subtask)", params: ["index?:int"], example: "-d '{}'")
        ep("POST", "/agent/crew-dispatch", "Dispatch a crew (objective + subtasks); MCP crewDispatch maps here", params: ["objective:string", "tasks:array", "isolated?:bool (ephemeral container, wiped on settle)"], example: "-d '{\"objective\":\"compare\",\"tasks\":[{\"url\":\"https://a\",\"instruction\":\"price of X\"}]}'")
        ep("POST", "/agent/tasks/create", "Create task", params: ["name:string", "prompt?:string", "minutes?:int | hour+minute", "window?:uuid (target a specific window; default = newest)", "builtin?:string (weeklyReport = built-in report pipeline; prompt unused)"], example: #"-d '{"name":"t","prompt":"p","minutes":30}'"#)
        ep("POST", "/agent/tasks/remove", "Remove by name", params: ["name:string"], example: "-d '{\"name\":\"t\"}'")
        ep("POST", "/agent/tasks/fire", "Deliver prompt now (E2E)", params: ["name:string"], example: "-d '{\"name\":\"t\"}'")
        ep("GET", "/approvals", "Pending tool approval", example: "…/approvals")
        ep("POST", "/approvals/resolve", "Resolve approval", params: ["decision:string"], example: #"-d '{"decision":"allow_once"}'"#)
        ep("POST", "/approvals/simulate", "Arm a REAL pending approval (no model turn)", example: "-d '{}'")
        ep("GET", "/beforeunload", "beforeunload guard state", params: ["index?:int"], example: "…/beforeunload")
        ep("POST", "/beforeunload/resolve", "Resolve guard (leave=true navigates)", params: ["leave:bool", "index?:int"], example: "-d '{\"leave\":false}'")
        ep("GET", "/reader", "Reader-mode extraction state", params: ["index?:int"], example: "…/reader")
        ep("GET", "/console", "Console messages", params: ["count?:int"], example: "…/console?count=20")
        // Misc
        ep("GET", "/settings", "A couple of global settings", example: "…/settings")
        ep("GET", "/mcp", "MCP server configs + tools", example: "…/mcp")
        ep("POST", "/mcp/remove", "Remove an MCP server by name", params: ["name:string"], example: #"-d '{"name":"local"}'"#)
        ep("GET", "/protocol/inspect", "Inspect the DPP protocol of the current page (views/signals/actions/context/warnings)", params: [], example: "…/protocol/inspect")
        ep("GET", "/search/everything", "Unified search across open tabs / history / bookmarks / reading list (Search Everywhere panel query)", params: ["q:string"], example: "…/search/everything?q=github")
        ep("GET", "/promotion/state", "Operations workbench: goals, posts (with metric history + growth), accounts (snapshots + growth), lessons, progress, digest (shared with the agent's promotionBrief tool)", example: "…/promotion/state")
        ep("POST", "/promotion/goal", "Add a promotion goal", params: ["title:string", "objective?:string", "platforms?:array", "targetPosts?:int", "dueDate?:string(yyyy-MM-dd|ISO8601)"], example: #"-d '{"title":"v0.7.15 发布宣传","platforms":["掘金"],"targetPosts":2}'"#)
        ep("POST", "/promotion/goal/remove", "Remove a promotion goal by id (posts keep their history, link cleared)", params: ["id:string"], example: #"-d '{"id":"<uuid>"}'"#)
        ep("POST", "/promotion/post", "Save or update a workbench post (idea/draft/published; pass id to update, plannedFor=yyyy-MM-dd) — same semantics as the agent's promotionSave tool", params: ["id?:string", "platform?:string", "title?:string", "body?:string", "status?:idea|draft|published", "url?:string", "goal?:string", "plannedFor?:string"], example: #"-d '{"platform":"掘金","title":"…","body":"…","status":"draft","plannedFor":"2026-10-20"}'"#)
        ep("POST", "/promotion/metrics", "Record engagement metrics for a post by id or published URL", params: ["idOrURL:string", "views?:int", "likes?:int", "comments?:int"], example: #"-d '{"idOrURL":"https://…","views":320,"likes":12}'"#)
        ep("POST", "/promotion/post/remove", "Remove a promotion post by id", params: ["id:string"], example: #"-d '{"id":"<uuid>"}'"#)
        ep("POST", "/promotion/account", "Register/update an operations account (upsert by domain+platform+handle)", params: ["platform:string", "handle:string", "domain?:promotion|media|ecommerce", "url?:string", "note?:string"], example: #"-d '{"platform":"掘金","handle":"siwi","domain":"media"}'"#)
        ep("POST", "/promotion/account/metrics", "Append an account snapshot (followers/views/likes) by id, exact handle or URL", params: ["idOrHandle:string", "followers?:int", "views?:int", "likes?:int"], example: #"-d '{"idOrHandle":"siwi","followers":1280}'"#)
        ep("POST", "/promotion/account/remove", "Remove an account by id", params: ["id:string"], example: #"-d '{"id":"<uuid>"}'"#)
        ep("POST", "/promotion/lesson", "Record an operations lesson (exact duplicates are skipped)", params: ["text:string", "domain?:promotion|media|ecommerce", "platform?:string"], example: #"-d '{"text":"掘金长文数据优于短沸点","platform":"掘金"}'"#)
        ep("POST", "/promotion/lesson/remove", "Remove a lesson by id", params: ["id:string"], example: #"-d '{"id":"<uuid>"}'"#)
        ep("POST", "/promotion/review", "Schedule (idempotent) or remove an operations automation task", params: ["kind?:dailyCollect|weeklyReview|dailyTopics", "action?:schedule|remove"], example: #"-d '{"kind":"dailyTopics"}'"#)
        ep("GET", "/promotion/report", "Operations weekly report as Markdown (shared with the promotionReport tool and the panel's copy button)", params: ["periodDays?:int"], example: "…/promotion/report?periodDays=7")
        ep("POST", "/promotion/interaction", "Log interaction(s) (comments/DMs/reviews) into the ledger — single object or {items:[…]}, duplicates skipped", params: ["platform?:string", "author?:string", "text?:string", "kind?:comment|dm|mention|review", "url?:string", "postTitle?:string", "items?:array"], example: #"-d '{"platform":"掘金","author":"u1","text":"好文！","url":"https://…"}'"#)
        ep("POST", "/promotion/interaction/reply", "Draft/close one interaction: store reply text and/or set status", params: ["id:string", "reply?:string", "status?:replied|ignored|pending"], example: #"-d '{"id":"<uuid>","reply":"谢谢支持！","status":"replied"}'"#)
        ep("POST", "/promotion/interaction/remove", "Remove an interaction by id", params: ["id:string"], example: #"-d '{"id":"<uuid>"}'"#)
        ep("GET", "/page/extract", "Run the agent's pageExtract tool against the selected tab (same implementation, read-only)", params: ["view:string", "all?:bool"], example: "…/page/extract?view=stories")
        ep("POST", "/page/dpp-action", "Run a declared DPP action via the agent toolchain — local-effect actions only (persist/outbound go through the agent approval loop)", params: ["name:string", "args?:object"], example: #"-d '{"name":"fill-article-title","args":{"title":"hi"}}'"#)
        ep("GET", "/dpp/modes", "Per-site DPP event automation modes (off/draft/auto)", example: "…/dpp/modes")
        ep("POST", "/dpp/mode", "Set the DPP event automation mode for a host", params: ["host:string", "mode:string(off|draft|auto)"], example: #"-d '{"host":"example.com","mode":"draft"}'"#)
        ep("GET", "/whiteboard", "Current conversation's whiteboard blocks (type/title/contentLength/200-char preview; ?conversationId= override; ?format=readout|markdown|png — png returns the share-card image as base64)", example: "…/whiteboard")
        ep("POST", "/whiteboard", "Drive the whiteboard: action=render (replace) | append | insert (with index) | clear | get (read back) | undo/redo | edit/delete/move (single block by 1-based index) | comment/comment-resolve/comment-delete (v0.7.24); blocks = [{type: mermaid|chart|note|table|image, title?, content}]", params: ["action?:string", "title?:string", "blocks?:array", "index?:int", "delta?:int", "content?:any", "text?:string (comment)", "blockIndex?:int (comment target, 1-based; omit = whole board)", "commentId?:string", "conversationId?:string"], example: #"-d '{"action":"append","blocks":[{"type":"note","title":"备注","content":"hi"}]}'"#)
        ep("GET", "/dpp/config", "Agent-side DPP config (enabled / promptHints / defaultEventMode / siteModes)", example: "…/dpp/config")
        ep("POST", "/dpp/config", "Set agent-side DPP config (omit fields to keep)", params: ["enabled?:bool", "promptHints?:bool", "defaultEventMode?:string(off|draft|auto)"], example: #"-d '{"enabled":true,"defaultEventMode":"auto"}'"#)
        ep("POST", "/dpp/context-toggle", "Disable/enable site-authored context injection for a host (design review #6)", params: ["host:string", "disabled?:bool"], example: #"-d '{"host":"example.com","disabled":true}'"#)
        ep("GET", "/dpp/adapters", "Third-party DPP adapter packages (list + enabled + loadErrors)", example: "…/dpp/adapters")
        ep("POST", "/dpp/adapters/verify", "Live-verify adapter packs against open matching tabs — reports per-view element counts (rot detection, design review #8)", example: "-d '{}'")
        ep("POST", "/dpp/adapters/import", "Import an adapter JSON file by absolute path (same-name = overwrite)", params: ["path:string"], example: #"-d '{"path":"/tmp/juejin.json"}'"#)
        ep("POST", "/dpp/adapters/install", "Install an adapter JSON from an http(s) URL (community distribution)", params: ["url:string"], example: #"-d '{"url":"https://…/juejin.json"}'"#)
        ep("POST", "/dpp/adapters/toggle", "Enable/disable an adapter by name", params: ["name:string", "enabled:bool"], example: #"-d '{"name":"juejin","enabled":false}'"#)
        ep("POST", "/dpp/adapters/remove", "Delete an adapter package", params: ["name:string"], example: #"-d '{"name":"juejin"}'"#)
        ep("GET", "/agent/approvals", "Pending tool approval (the card waiting in the panel)", example: "…/agent/approvals")
        ep("POST", "/agent/approvals/resolve", "Resolve the pending approval from outside the panel (agent full-loop E2E without a human click)", params: ["decision:string(allowOnce|alwaysAllow|deny)"], example: #"-d '{"decision":"allowOnce"}'"#)
        ep("POST", "/mcp/add", "Add an MCP server (omit command for HTTP url; command = stdio argv, space-separated with quotes)", params: ["name:string", "url?:string", "command?:string"], example: #"-d '{"name":"local","command":"python3 /tmp/mcp.py"}'"#)
        ep("POST", "/responsive", "Toggle responsive design mode", params: ["enabled?:bool", "preset?:string", "index?:int", "pixelRatio?:number"], example: "-d '{\"enabled\":true,\"pixelRatio\":3}'")
        ep("GET", "/spawn-test", "Probe: spawn system binaries", example: "…/spawn-test")
        return eps
    }()

    /// Machine-readable driver documentation: endpoint catalog + SSE events.
    private static func index() throws -> [String: Any] {
        let events: [[String: Any]] = [
            ["event": "pageReady", "payload": ["url", "title"], "when": "a tab finished loading"],
            ["event": "downloadStarted", "payload": ["id", "file", "source"]],
            ["event": "downloadCompleted", "payload": ["id", "file", "bytes", "private"]],
            ["event": "downloadFailed", "payload": ["id", "file", "error"]],
            ["event": "approvalPending", "payload": ["tool", "risk"], "resolve": "POST /approvals/resolve"],
            ["event": "tabOpened", "payload": ["index", "count"]],
            ["event": "tabClosed", "payload": ["closedId", "count"]],
            ["event": "beforeunloadPending", "payload": ["url", "message"], "resolve": "POST /beforeunload/resolve"],
        ]
        return [
            "service": "Desire Automation Bridge",
            "baseUrl": baseURL,
            "auth": "optional — launch with `--automation-token <token>`, send `Authorization: Bearer <token>`",
            "events": ["transport": "SSE", "path": "/events", "kinds": events],
            "endpoints": endpointCatalog,
        ]
    }

    // MARK: - Routing

    /// Single-entry API for in-app consumers of the bridge pipeline (the
    /// MCP server's tools route through here, so both surfaces stay in
    /// sync). Returns the endpoint's JSON body string.
    func callEndpoint(method: String, path: String, json: [String: Any]? = nil, window: String? = nil) async -> String {
        var request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let window {
            request += "X-Desire-Window: \(window)\r\n"
        }
        var bodyText = ""
        if let json, let data = try? JSONSerialization.data(withJSONObject: json) {
            bodyText = String(data: data, encoding: .utf8) ?? ""
            request += "Content-Type: application/json\r\nContent-Length: \(bodyText.count)\r\n"
        }
        request += "\r\n" + bodyText
        return await route(request)
    }

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
            // maxSplits 1：值里允许带 `=`（如 scope=tab=<uuid>）——此前按 2 切，
            // 三段的键值对被整对丢弃（0.7.5 HAR 端点首踩）。
            for pair in pathComponents[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
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
            case ("GET", "/"):
                return try Self.json(Self.index())
            case ("GET", "/state"):
                return try Self.json(Self.appState())
            case ("POST", "/navigate"):
                return try await Self.json(Self.navigate(Self.string(body, "url"), index: Self.index(body)))
            case ("POST", "/video-speed"):
                // 视频速度接管（0.6.5）：rate 钳制 0.25–3，经 video-speed.js
                // 应用到当前与未来媒体元素。E2E：executeJS 读 playbackRate 断言。
                guard let session = Self.resolveSession(Self.string(body, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                guard let rate = (body["rate"] as? Double) ?? (Self.string(body, "rate").flatMap(Double.init)) else {
                    return try Self.json(["error": "rate required (0.25–3)"])
                }
                let clamped = min(3, max(0.25, rate))
                session.boundTabManager?.selectedTab?.browser.setPlaybackRate(clamped)
                return try Self.json(["ok": true, "rate": clamped])
            case ("POST", "/back"):
                return try await Self.json(Self.goBack(index: Self.index(body)))
            case ("POST", "/forward"):
                return try await Self.json(Self.goForward(index: Self.index(body)))
            case ("POST", "/reload"):
                return try await Self.json(Self.reload(index: Self.index(body)))
            case ("POST", "/new-tab"):
                return try await Self.json(Self.newTab(
                    url: Self.string(body, "url"),
                    incognito: body["incognito"] as? Bool ?? false,
                    container: Self.string(body, "container")
                ))
            case ("POST", "/close-tab"):
                return try await Self.json(Self.closeTab(index: Self.index(body)))
            case ("POST", "/switch-tab"):
                return try await Self.json(Self.switchTab(index: Self.index(body) ?? 0))
            case ("GET", "/page/text"):
                return try await Self.json(Self.pageText(index: Self.index(query)))
            case ("GET", "/find"):
                return try await Self.json(Self.find(
                    query: query["q"] ?? "",
                    index: Self.index(query),
                    caseSensitive: query["caseSensitive"] == "1"))
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
            case ("POST", "/screenshot/fullpage"):
                return try await Self.json(Self.fullPageScreenshot(index: Self.index(body)))
            case ("GET", "/screenshot"):
                return try await Self.json(Self.screenshot(
                    index: Self.index(query),
                    inline: query["inline"] == "1"
                ))
            case ("GET", "/history"):
                if query["grouped"] == "1" {
                    return try Self.json(Self.historyGrouped())
                }
                return try Self.json(Self.history(count: Int(query["count"] ?? "10") ?? 10))
            case ("GET", "/diag/geometry"):
                return try Self.json(Self.geometry(index: Self.index(query)))
            case ("GET", "/diag/browser"):
                return try Self.json(BrowserDiagnostics.shared.summary())
            case ("GET", "/activity"):
                return try Self.json(ActivityCenter.summary(
                    ActivityCenter.build(ActivityCenterCollector.liveInputs())))
            case ("POST", "/diag/export"):
                return try Self.json(Self.diagExport())
            case ("POST", "/workflow/start"):
                return try Self.json(Self.workflowStart())
            case ("POST", "/workflow/stop"):
                return try Self.json(Self.workflowStop(name: Self.string(body, "name") ?? ""))
            case ("GET", "/workflow/list"):
                return try Self.json(Self.workflowList())
            case ("POST", "/workflow/run"):
                return try Self.json(await Self.workflowRun(body: body))
            case ("POST", "/workflow/delete"):
                return try Self.json(Self.workflowDelete(id: Self.string(body, "id") ?? ""))
            case ("POST", "/workflow/offer"):
                return try Self.json(Self.workflowOffer(body: body))
            case ("POST", "/workflow/suggestion/dismiss"):
                TabSessionCoordinator.shared.activeTabManager?.selectedTab?
                    .browser.pendingWorkflowSuggestion = nil
                return try Self.json(["ok": true])
            case ("POST", "/backup/export"):
                return try Self.json(Self.backupExport(body: body))
            case ("POST", "/backup/import"):
                return try Self.json(Self.backupImport(body: body))
            case ("POST", "/backup/preview"):
                return try Self.json(Self.backupPreview(body: body))
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
                guard let tab = Self.shared.resolveIndex(Self.index(body)) else {
                    return Self.error("no such tab")
                }
                let enabled = body["enabled"] as? Bool ?? true
                if let presetName = Self.string(body, "preset"),
                   let preset = devicePresets.first(where: { $0.name == presetName }) {
                    tab.responsiveConfig.selectedPresetID = preset.id
                    tab.responsiveConfig.customWidth = preset.width
                    tab.responsiveConfig.customHeight = preset.height
                }
                let pixelRatio = (body["pixelRatio"] as? Double) ?? (Self.string(body, "pixelRatio").flatMap(Double.init))
                let size = tab.responsiveConfig.effectiveSize
                // 配置变更**异步**执行（0.6.6）：同步走会触发 SwiftUI onChange →
                // Applier（UA 换装/触摸模拟/DPR 覆写三层 evaluateJavaScript），
                // 响应发不出去、桥 listener 随后整体失联（E2E 实测）。跳一帧
                // 再改配置，响应先回。
                Task { @MainActor in
                    tab.responsiveConfig.isEnabled = enabled   // onChange → Applier
                    if let pixelRatio {
                        tab.responsiveConfig.pixelRatio = min(4, max(1, pixelRatio))
                    }
                }
                // 注意：size 是 CGSize——NSJSONSerialization 不能序列化，
                // ObjC 异常穿 async 帧会把主 actor 打成僵尸（桥全灭）。
                return try Self.json([
                    "ok": true, "enabled": enabled,
                    "size": ["width": Double(size.width), "height": Double(size.height)],
                    "pixelRatio": pixelRatio ?? tab.responsiveConfig.pixelRatio,
                ])
            case ("GET", "/approvals"):
                return try Self.json(Self.pendingApproval(window: Self.string(query, "window")))
            case ("GET", "/beforeunload"):
                return try Self.json(Self.beforeUnloadState(index: Self.index(query)))
            case ("POST", "/history/remove"):
                guard let app = AppState.live, let id = UUID(uuidString: Self.string(body, "id") ?? "") else {
                    return try Self.json(["error": "missing/invalid id"])
                }
                app.historyStore.removeEntry(id: id)
                return try Self.json(["ok": true])
            case ("GET", "/history/content"):
                return try Self.json(Self.historyContentSearch(
                    query: Self.string(query, "q") ?? "",
                    limit: Int(Self.string(query, "limit") ?? "") ?? 20))
            case ("GET", "/history/content/stats"):
                return try Self.json(Self.historyContentStats())
            case ("POST", "/history/content"):
                return try Self.json(Self.historyContentSetEnabled(
                    body["enabled"] as? Bool ?? false))
            case ("POST", "/history/content/clear"):
                return try Self.json(Self.historyContentClear())
            case ("GET", "/whatsnew"):
                return try Self.json(Self.whatsNewState())
            case ("POST", "/whatsnew/show"):
                WhatsNewStore.shared.show()
                return try Self.json(Self.whatsNewState())
            case ("POST", "/whatsnew/dismiss"):
                WhatsNewStore.shared.dismiss()
                return try Self.json(Self.whatsNewState())
            case ("POST", "/whatsnew/reset"):
                WhatsNewStore.shared.resetForTesting()
                return try Self.json(Self.whatsNewState())
            case ("GET", "/reader"):
                return try Self.json(Self.readerState(index: Self.index(query)))
            case ("GET", "/console"):
                return try Self.json(Self.console(count: Int(query["count"] ?? "20") ?? 20))
            case ("GET", "/plugins"):
                return try Self.json(Self.pluginList())
            case ("GET", "/plugins/dnr"):
                // DNR 诊断：三源规则数 + 编译丢弃清单。
                guard let uuid = UUID(uuidString: Self.string(query, "id") ?? "") else {
                    return try Self.json(["error": "invalid id"])
                }
                return try Self.json(PluginDNRStore.shared.diagnostics(pluginID: uuid))
            case ("GET", "/webext/debug"):
                return try Self.json(ExtensionEventHub.shared.debugInfo())
            case ("POST", "/webext/fire"):
                let tm = try tabManager
                guard let tab = tm?.selectedTab else { return try Self.json(["error": "no selected tab"]) }
                ExtensionEventHub.shared.fire(
                    Self.string(body, "event") ?? "tabs.onActivated",
                    tabID: tab.id,
                    extra: ["probe": true]
                )
                return try Self.json(["ok": true])
            case ("POST", "/webext/eval"):
                let tm = try tabManager
                guard let tab = tm?.selectedTab else { return try Self.json(["error": "no selected tab"]) }
                let js = Self.string(body, "js") ?? ""
                let result: String = await withCheckedContinuation { cont in
                    tab.browser.webView.evaluateJavaScript(js, in: nil, in: WebView.extensionWorld) { value in
                        switch value {
                        case .success(let v): cont.resume(returning: String(describing: v))
                        case .failure(let error): cont.resume(returning: "ERROR: \(error.localizedDescription)")
                        }
                    }
                }
                return try Self.json(["result": result])
            case ("POST", "/plugins/add"):
                return try Self.json(Self.pluginAdd(
                    name: Self.string(body, "name") ?? "",
                    js: Self.string(body, "js") ?? "",
                    patterns: body["patterns"] as? [String] ?? ["*"],
                    runAt: Self.string(body, "runAt") ?? "document_end",
                    css: Self.string(body, "css") ?? "",
                    pinned: body["pinned"] as? Bool ?? false,
                    icon: Self.string(body, "icon"),
                    background: Self.string(body, "background")
                ))
            case ("POST", "/plugins/install-msex"):
                guard let app = AppState.live else { return try Self.json(["error": "app state not ready"]) }
                let path = Self.string(body, "path") ?? ""
                guard FileManager.default.fileExists(atPath: path) else {
                    return try Self.json(["error": "file not found: \(path)"])
                }
                do {
                    // 目录 = 已解压扩展（Chrome 式"从文件夹加载"）→ Safari 包管线
                    var isDir: ObjCBool = false
                    let isDirectory = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                    let result = isDirectory
                        ? try MSExInstaller.installSafariPackage(from: URL(fileURLWithPath: path), store: app.pluginStore)
                        : try MSExInstaller.install(from: URL(fileURLWithPath: path), store: app.pluginStore)
                    return try Self.json([
                        "ok": true,
                        "id": result.plugin.id.uuidString,
                        "name": result.plugin.name,
                        "hasPopup": result.plugin.popupHTML != nil,
                    ])
                } catch {
                    return try Self.json(["error": error.localizedDescription])
                }
            case ("GET", "/plugins/context-menus"):
                let app = AppState.live
                let enabled = Set(app?.pluginStore.plugins.filter { $0.isEnabled && $0.backgroundCode != nil }.map(\.id) ?? [])
                let items = PluginContextMenuStore.shared.visibleItems(enabledPluginIDs: enabled)
                return try Self.json(["menus": items.map { item -> [String: Any] in
                    ["pluginId": item.pluginID.uuidString, "menuId": item.menuID,
                     "title": item.title, "contexts": item.contexts]
                }])
            case ("POST", "/plugins/context-menus/click"):
                guard let pluginID = Self.string(body, "pluginId").flatMap(UUID.init),
                      let menuID = Self.string(body, "menuId") else {
                    return try Self.json(["error": "missing pluginId/menuId"])
                }
                PluginBackgroundRuntime.shared.contextMenuClick(
                    pluginID: pluginID, menuItemID: menuID,
                    pageURL: Self.string(body, "pageUrl").flatMap(URL.init),
                    linkURL: Self.string(body, "linkUrl").flatMap(URL.init),
                    srcURL: Self.string(body, "srcUrl").flatMap(URL.init),
                    selectionText: Self.string(body, "selectionText"))
                return try Self.json(["ok": true])
            case ("POST", "/plugins/bg-eval"):
                // 在插件 background webview 里求值（调试/E2E——背景页没有
                // 桥可达的 world，此前只能靠 content script 转发探针）。
                guard let uuid = UUID(uuidString: Self.string(body, "id") ?? "") else {
                    return try Self.json(["error": "invalid id"])
                }
                guard let bgWeb = PluginBackgroundRuntime.shared.backgroundWebview(for: uuid) else {
                    return try Self.json(["error": "no background host (plugin disabled or no background)"])
                }
                let bgJS = Self.string(body, "js") ?? ""
                let bgResult: Any? = await withCheckedContinuation { cont in
                    bgWeb.evaluateJavaScript(bgJS, in: nil, in: .page) { result in
                        switch result {
                        case .success(let value): cont.resume(returning: value)
                        case .failure: cont.resume(returning: NSNull())
                        }
                    }
                }
                return try Self.json(["result": bgResult ?? NSNull()])
            case ("POST", "/plugins/pin"):
                let app = AppState.live
                guard let uuid = UUID(uuidString: Self.string(body, "id") ?? "") else {
                    return try Self.json(["error": "invalid id"])
                }
                guard app?.pluginStore.plugins.contains(where: { $0.id == uuid }) == true else {
                    return try Self.json(["error": "no such plugin"])
                }
                // 显式 pinned=true/false 设定；缺省为切换。
                if let pinned = body["pinned"] as? Bool {
                    app?.pluginStore.setPinned(uuid, pinned)
                } else {
                    app?.pluginStore.togglePin(uuid)
                }
                return try Self.json(["ok": true])
            case ("POST", "/plugins/remove"):
                return try Self.json(Self.pluginRemove(id: Self.string(body, "id") ?? ""))
            case ("GET", "/passwords"):
                return try Self.json(Self.passwords())
    case ("GET", "/search/everything"):
            // 集中搜索的桥面（SearchEverywhere 同一查询）：四源结构化断言。
            guard let q = Self.string(query, "q"), !q.isEmpty else {
                return try Self.json(["error": "missing q"])
            }
            var items: [[String: Any]] = []
            if let tm = TabSessionCoordinator.shared.activeTabManager {
                for (idx, tab) in tm.tabs.enumerated() {
                    items.append(["source": "tab", "index": idx,
                                  "title": tab.displayTitle,
                                  "url": tab.browser.webView.url?.absoluteString ?? tab.urlString])
                }
            }
            if let hs = AppState.live?.historyStore {
                for e in hs.entries where e.title.lowercased().contains(q.lowercased()) || e.url.lowercased().contains(q.lowercased()) {
                    items.append(["source": "history", "title": e.title, "url": e.url])
                }
            }
            if let bs = AppState.live?.bookmarkStore {
                func walk(_ nodes: [Bookmark]) {
                    for b in nodes {
                        if let url = b.url, b.title.lowercased().contains(q.lowercased()) || url.lowercased().contains(q.lowercased()) {
                            items.append(["source": "bookmark", "title": b.title, "url": url])
                        }
                        walk(b.children)
                    }
                }
                walk(bs.bookmarks)
            }
            if let rl = AppState.live?.readingListStore {
                for i in rl.items where i.title.lowercased().contains(q.lowercased()) || i.url.lowercased().contains(q.lowercased()) {
                    items.append(["source": "readingList", "title": i.title, "url": i.url])
                }
            }
            return try Self.json(["q": q, "results": items])

            // ── 运营工作台（0.7.15）─────────────────────────────
            case ("GET", "/promotion/state"):
                return try Self.json(Self.promotionState())
            case ("POST", "/promotion/goal"):
                return try Self.json(Self.promotionGoalAdd(body))
            case ("POST", "/promotion/goal/remove"):
                return try Self.json(Self.promotionGoalRemove(body))
            case ("POST", "/promotion/post"):
                return try Self.json(Self.promotionPostSave(body))
            case ("POST", "/promotion/metrics"):
                return try Self.json(Self.promotionMetricsSave(body))
            case ("POST", "/promotion/post/remove"):
                return try Self.json(Self.promotionPostRemove(body))
            case ("POST", "/promotion/account"):
                return try Self.json(Self.promotionAccountSave(body))
            case ("POST", "/promotion/account/metrics"):
                return try Self.json(Self.promotionAccountMetricsSave(body))
            case ("POST", "/promotion/account/remove"):
                return try Self.json(Self.promotionAccountRemove(body))
            case ("POST", "/promotion/lesson"):
                return try Self.json(Self.promotionLessonAdd(body))
            case ("POST", "/promotion/lesson/remove"):
                return try Self.json(Self.promotionLessonRemove(body))
            case ("POST", "/promotion/review"):
                return try Self.json(Self.promotionReview(body))
            case ("GET", "/promotion/report"):
                return try Self.json(Self.promotionReport(query))
            case ("POST", "/promotion/interaction"):
                return try Self.json(Self.promotionInteractionLog(body))
            case ("POST", "/promotion/interaction/reply"):
                return try Self.json(Self.promotionInteractionReply(body))
            case ("POST", "/promotion/interaction/remove"):
                return try Self.json(Self.promotionInteractionRemove(body))

            case ("GET", "/protocol/inspect"):
                // index? 指定标签（多窗口下 deliveryTarget 的窗口未必是
                // active 窗口——E2E 实测错位）；缺省 = deliveryTarget 的 selected。
                let inspectedTab = Self.shared.resolveIndex(Self.index(query))
                    ?? AgentScheduler.shared.deliveryTarget?.boundTabManager?.selectedTab
                guard let dpp = inspectedTab?.browser.effectiveProtocol else {
                    return try Self.json(["declared": false])
                }
                var views: [String: Any] = [:]
                for (name, view) in dpp.views {
                    // fields 显式摊平成 String→String——自定义 struct 直接进
                    // JSONSerialization 会静默产出空响应（非 plist 类型）。
                    views[name] = ["item": view.item,
                                   "fields": view.fields.mapValues { $0.expression },
                                   "pagination": view.pagination?.type ?? "none"]
                }
                let dppHost = inspectedTab?.browser.webView.url?.host ?? ""
                return try Self.json([
                    "declared": true, "version": dpp.protocolVersion,
                    "profile": dpp.profile ?? "",
                    "pages": dpp.pages.count,
                    "pageType": dpp.pageType ?? "", "contentMain": dpp.contentMain ?? "",
                    "sections": dpp.sections,
                    "ignore": dpp.ignore, "views": views,
                    "signals": dpp.signals,
                    "actions": dpp.actions.map { ["name": $0.name, "description": $0.description ?? "",
                                                  "effects": $0.effects ?? "local", "danger": $0.danger ?? false] },
                    "events": dpp.events,
                    "context": dpp.context,
                    "warnings": dpp.warnings,
                    "eventMode": PageEventHub.shared.mode(for: dppHost),
                    "siteLevel": inspectedTab?.browser.siteProtocol != nil,
                ])
            case ("GET", "/dpp/modes"):
                return try Self.json(["modes": PageEventHub.shared.siteModes])
            case ("GET", "/agentball"):
                return try Self.json([
                    "visible": AgentBallPanel.shared.isVisible,
                    "enabled": AgentBallPanel.shared.isEnabled,
                    "expanded": AgentBallPanel.shared.isExpanded,
                    "showsAll": AgentBallPanel.shared.hubShowsAll,
                    "slots": AgentBallPanel.shared.encodedSlots,
                    "agentBusy": AgentBallPanel.shared.agentBusy,
                    "hiddenForFullscreen": AgentBallPanel.shared.hiddenForFullscreen,
                    "actionToast": AgentBallPanel.shared.actionToast ?? "",
                ])
            case ("POST", "/agentball"):
                // 开合/显隐驱动（darwin 27 上 CGEvent 已死、球又是手势判定
                // 不是 AXButton——这是悬浮球唯一的自动化入口；E2E 截图用）。
                if let expanded = body["expanded"] as? Bool {
                    AgentBallPanel.shared.isExpanded = expanded
                }
                if let enabled = body["enabled"] as? Bool {
                    AgentBallPanel.shared.setEnabled(enabled)
                }
                if let showsAll = body["showsAll"] as? Bool {
                    AgentBallPanel.shared.hubShowsAll = showsAll
                }
                // 等价一次拖放松手（动作选择菜单的验证入口）。
                if let drop = body["pendingDrop"] as? String {
                    AgentBallPanel.shared.deliverDrop(drop)
                }
                if body["cancelDrop"] as? Bool == true {
                    AgentBallPanel.shared.cancelDrop()
                }
                // v7 触发槽位能力（快捷动作 E2E 入口）：perform 后读
                // GET /agentball 的 actionToast 断言结果反馈。
                if let name = body["perform"] as? String,
                   let capability = BallCapability(rawValue: name) {
                    AgentBallPanel.shared.perform(capability)
                }
                return try Self.json([
                    "ok": true,
                    "enabled": AgentBallPanel.shared.isEnabled,
                    "expanded": AgentBallPanel.shared.isExpanded,
                    "showsAll": AgentBallPanel.shared.hubShowsAll,
                ])
            case ("GET", "/whiteboard"):
                if query["format"] == "png" {
                    // 分享卡导出（自动化/远程）：BoardRenderService 离屏成图。
                    let session = AgentScheduler.shared.deliveryTarget
                    let board = session.map { WhiteboardStore.shared.board(for: $0.conversationId?.uuidString) }
                        ?? WhiteboardStore.shared.mostRecentBoard()
                        ?? WhiteboardSpec()
                    guard !board.blocks.isEmpty else {
                        return try Self.json(["error": "board is empty"])
                    }
                    let image = try await BoardRenderService.shareCardImage(board: board)
                    guard let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        return try Self.json(["error": "png encode failed"])
                    }
                    return try Self.json([
                        "format": "png",
                        "title": board.title,
                        "base64": png.base64EncodedString(),
                    ])
                }
                let store = WhiteboardStore.shared
                let conversationID = query["conversationId"]
                    ?? AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
                let board = conversationID.map { store.board(for: $0) } ?? store.mostRecentBoard() ?? WhiteboardSpec()
                // ?format=readout：模型所见文本（get 动作同款），断言"模型看到什么"用
                if let format = Self.string(query, "format") {
                    if format == "readout" {
                        return try Self.json(["conversationId": conversationID ?? "", "readout": board.readout()])
                    }
                    if format == "markdown" {
                        return try Self.json(["conversationId": conversationID ?? "", "markdown": board.markdownExport()])
                    }
                    if format == "pdf" {
                        // PDF 导出（v0.7.24）：A4 分页；空板明确报错。
                        guard !board.blocks.isEmpty else {
                            return try Self.json(["error": "board is empty"])
                        }
                        let result = try await WhiteboardPDFExport.pdfData(board: board)
                        return try Self.json([
                            "conversationId": conversationID ?? "",
                            "format": "pdf",
                            "title": board.title,
                            "pages": result.pages,
                            "base64": result.data.base64EncodedString(),
                        ])
                    }
                }
                return try Self.json([
                    "conversationId": conversationID ?? "",
                    "title": board.title,
                    // 评论（v0.7.24）：blockNumber 0 = 整板；随白板域同步。
                    "comments": board.comments?.map {
                        ["id": $0.id.uuidString,
                         "text": $0.text,
                         "author": $0.author,
                         "blockNumber": board.blockNumber(of: $0.blockID) ?? 0,
                         "resolved": !$0.isOpen,
                         "createdAt": $0.createdAt.timeIntervalSince1970]
                    } ?? [],
                    // preview = 每块内容前 200 字符（断言块语义用；image 块
                    // 只报 URI 前缀，不回传万级 base64）。
                    "blocks": board.blocks.map {
                        ["type": $0.type,
                         "title": $0.title ?? "",
                         "contentLength": $0.content.count,
                         "preview": $0.type == WhiteboardBlock.Kind.image
                             ? String($0.content.prefix(30))
                             : String($0.content.prefix(200))]
                    },
                ])
            case ("POST", "/whiteboard"):
                // 自动化写入口（与 whiteboard 工具同权：render/append/clear/get/
                // edit/delete/move）。写操作走 UI 持有的 WhiteboardStore.shared；
                // conversationId 可显式指定（缺省 = 活跃会话）。
                let store = WhiteboardStore.shared
                let action = Self.string(body, "action") ?? "render"
                let conversationID = Self.string(body, "conversationId")
                    ?? AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
                if action == "get" {
                    let board = store.board(for: conversationID)
                    return try Self.json([
                        "ok": true,
                        "title": board.title,
                        "blocks": board.blocks.map { ["type": $0.type, "title": $0.title ?? "", "contentLength": $0.content.count] },
                    ])
                }
                if action == "clear" {
                    store.clear(conversationID: conversationID)
                    return try Self.json(["ok": true, "action": "clear", "blockCount": 0])
                }
                if action == "undo" || action == "redo" {
                    let ok = action == "undo"
                        ? store.undo(conversationID: conversationID)
                        : store.redo(conversationID: conversationID)
                    return try Self.json([
                        "ok": ok, "action": action,
                        "blockCount": store.board(for: conversationID).blocks.count])
                }
                // 单块精细编辑（index 为 1-based 块号，与工具/get 同口径）。
                if action == "edit" || action == "delete" || action == "move" {
                    let number = (body["index"] as? Int)
                        ?? (body["index"] as? Double).map(Int.init)
                        ?? (body["index"] as? String).flatMap(Int.init)
                    guard let number else {
                        return try Self.json(["error": "Missing index (1-based block number)"])
                    }
                    let board = store.board(for: conversationID)
                    let index = number - 1
                    guard board.blocks.indices.contains(index) else {
                        return try Self.json(["error": "Block index \(number) out of range (board has \(board.blocks.count) block(s))"])
                    }
                    switch action {
                    case "edit":
                        guard let rawContent = body["content"] else {
                            return try Self.json(["error": "Missing content for edit"])
                        }
                        let contentText: String
                        if let text = rawContent as? String {
                            contentText = text
                        } else if JSONSerialization.isValidJSONObject(rawContent),
                                  let data = try? JSONSerialization.data(withJSONObject: rawContent),
                                  let text = String(data: data, encoding: .utf8) {
                            contentText = text
                        } else {
                            return try Self.json(["error": "content must be a string or a JSON object"])
                        }
                        let updated = board.editingBlock(index, content: contentText)
                        guard updated.blocks[index].isValid else {
                            return try Self.json(["error": "Invalid content for \(board.blocks[index].type) block"])
                        }
                        store.set(updated, conversationID: conversationID)
                        return try Self.json(["ok": true, "action": "edit", "blockCount": updated.blocks.count])
                    case "delete":
                        let updated = board.deletingBlock(index)
                        store.set(updated, conversationID: conversationID)
                        return try Self.json(["ok": true, "action": "delete", "blockCount": updated.blocks.count])
                    default:
                        let delta = (body["delta"] as? Int)
                            ?? (body["delta"] as? Double).map(Int.init)
                            ?? (body["delta"] as? String).flatMap(Int.init)
                            ?? 1
                        let updated = board.movingBlock(index, delta: delta)
                        guard updated != board else {
                            return try Self.json(["error": "Move out of range"])
                        }
                        store.set(updated, conversationID: conversationID)
                        return try Self.json(["ok": true, "action": "move", "blockCount": updated.blocks.count])
                    }
                }
                // 评论动作（v0.7.24）：comment / comment-resolve / comment-delete。
                if action == "comment" {
                    var blockID: UUID?
                    if let number = (body["blockIndex"] as? Int)
                        ?? (body["blockIndex"] as? Double).map(Int.init)
                        ?? (body["blockIndex"] as? String).flatMap(Int.init) {
                        let board = store.board(for: conversationID)
                        guard board.blocks.indices.contains(number - 1) else {
                            return try Self.json(["error": "Block index \(number) out of range (board has \(board.blocks.count) block(s))"])
                        }
                        blockID = board.blocks[number - 1].id
                    }
                    guard let commentID = store.addComment(
                        text: Self.string(body, "text") ?? "",
                        blockID: blockID, conversationID: conversationID) else {
                        return try Self.json(["error": "Missing text"])
                    }
                    let board = store.board(for: conversationID)
                    return try Self.json(["ok": true, "action": "comment",
                                          "commentId": commentID.uuidString,
                                          "openCount": board.openCommentCount])
                }
                if action == "comment-resolve" || action == "comment-delete" {
                    guard let raw = Self.string(body, "commentId"),
                          let commentID = UUID(uuidString: raw) else {
                        return try Self.json(["error": "Missing/invalid commentId"])
                    }
                    if action == "comment-resolve" {
                        store.toggleCommentResolved(commentID, conversationID: conversationID)
                    } else {
                        store.deleteComment(commentID, conversationID: conversationID)
                    }
                    let board = store.board(for: conversationID)
                    return try Self.json(["ok": true, "action": action,
                                          "commentCount": board.comments?.count ?? 0,
                                          "openCount": board.openCommentCount])
                }
                guard var rawBlocks = body["blocks"] as? [[String: Any]], !rawBlocks.isEmpty else {
                    return try Self.json(["error": "Missing blocks array (action=render|append)"])
                }
                if let evidenceError = WhiteboardEvidence.resolve(
                    &rawBlocks,
                    messages: AgentScheduler.shared.deliveryTarget?.messages ?? []) {
                    return try Self.json(["error": evidenceError])
                }
                let blocks = rawBlocks.prefix(12).compactMap(WhiteboardBlock.make(from:))
                guard !blocks.isEmpty else {
                    return try Self.json(["error": "No valid blocks (mermaid|chart|note|table|image)"])
                }
                let title = Self.string(body, "title")
                if action == "append" || action == "insert" {
                    let existing = store.board(for: conversationID).blocks.count
                    guard existing + blocks.count <= WhiteboardSpec.maxBlocks else {
                        return try Self.json(["error": "Board would exceed \(WhiteboardSpec.maxBlocks) blocks"])
                    }
                    if action == "insert" {
                        let number = (body["index"] as? Int)
                            ?? (body["index"] as? Double).map(Int.init)
                            ?? (body["index"] as? String).flatMap(Int.init)
                            ?? (existing + 1)
                        let at = number - 1
                        guard at >= 0, at <= existing else {
                            return try Self.json(["error": "Insert index \(number) out of range (board has \(existing) block(s))"])
                        }
                        store.apply({ $0 = $0.insertingBlocks(blocks, at: at) }, conversationID: conversationID)
                    } else {
                        store.append(blocks, title: title, conversationID: conversationID)
                    }
                } else {
                    store.set(WhiteboardSpec(title: title ?? "白板", blocks: blocks), conversationID: conversationID)
                }
                return try Self.json([
                    "ok": true,
                    "action": action,
                    "blockCount": store.board(for: conversationID).blocks.count,
                ])
            case ("GET", "/dpp/config"):
                let config = DPPConfigStore.shared
                return try Self.json([
                    "enabled": config.enabled,
                    "promptHints": config.promptHints,
                    "defaultEventMode": config.defaultEventMode,
                    "siteModes": PageEventHub.shared.siteModes,
                    "contextDisabledHosts": Array(config.contextDisabledHosts).sorted(),
                ])
            case ("POST", "/dpp/context-toggle"):
                // per-host 语义上下文注入开关（设计评审 #6）。
                guard let host = Self.string(body, "host"), !host.isEmpty else {
                    return try Self.json(["error": "missing host"])
                }
                let disabled = body["disabled"] as? Bool ?? true
                DPPConfigStore.shared.setContextDisabled(disabled, for: host)
                return try Self.json(["ok": true, "host": host, "contextDisabled": disabled])
            case ("POST", "/dpp/config"):
                let config = DPPConfigStore.shared
                if let enabled = body["enabled"] as? Bool { config.setEnabled(enabled) }
                if let hints = body["promptHints"] as? Bool { config.setPromptHints(hints) }
                if let mode = Self.string(body, "defaultEventMode") {
                    guard [PageEventHub.modeOff, PageEventHub.modeDraft, PageEventHub.modeAuto].contains(mode) else {
                        return try Self.json(["error": "defaultEventMode must be off|draft|auto"])
                    }
                    config.setDefaultEventMode(mode)
                }
                return try Self.json([
                    "ok": true,
                    "enabled": config.enabled,
                    "promptHints": config.promptHints,
                    "defaultEventMode": config.defaultEventMode,
                ])
            case ("POST", "/dpp/mode"):
                guard let host = Self.string(body, "host"), !host.isEmpty else {
                    return try Self.json(["error": "missing host"])
                }
                let mode = Self.string(body, "mode") ?? "draft"
                guard [PageEventHub.modeOff, PageEventHub.modeDraft, PageEventHub.modeAuto].contains(mode) else {
                    return try Self.json(["error": "mode must be off|draft|auto"])
                }
                PageEventHub.shared.setMode(mode, for: host)
                return try Self.json(["ok": true, "host": host, "mode": PageEventHub.shared.mode(for: host)])
            case ("GET", "/dpp/adapters"):
                // 第三方适配包（2026-10-10）：列表 + 启停 + 坏包错误。
                let store = DPPAdapterStore.shared
                return try Self.json([
                    "adapters": store.adapters.map { a in
                        ["name": a.name, "hosts": a.hosts, "pathPrefixes": a.pathPrefixes,
                         "enabled": store.isEnabled(a), "notes": a.notes,
                         "health": store.health(of: a.name),
                         "sourceURL": a.sourceURL ?? "",
                         "installedAt": a.installedAt?.timeIntervalSince1970 ?? 0,
                         "views": Array(a.protocolBody.views.keys),
                         "actions": a.protocolBody.actions.map(\.name)]
                    },
                    "loadErrors": store.loadErrors,
                ])
            case ("POST", "/dpp/adapters/import"):
                guard let path = Self.string(body, "path") else {
                    return try Self.json(["error": "missing path"])
                }
                do {
                    let a = try DPPAdapterStore.shared.importFile(at: URL(fileURLWithPath: path))
                    return try Self.json(["ok": true, "name": a.name, "hosts": a.hosts])
                } catch {
                    return try Self.json(["error": error.localizedDescription])
                }
            case ("POST", "/dpp/adapters/install"):
                // URL 安装（社区分发闭环）：拉取校验落盘。
                guard let source = Self.string(body, "url") else {
                    return try Self.json(["error": "missing url"])
                }
                do {
                    let a = try await DPPAdapterStore.shared.installFromURL(source)
                    return try Self.json(["ok": true, "name": a.name, "hosts": a.hosts])
                } catch {
                    return try Self.json(["error": error.localizedDescription])
                }
            case ("POST", "/dpp/adapters/toggle"):
                guard let name = Self.string(body, "name"), let enabled = body["enabled"] as? Bool else {
                    return try Self.json(["error": "name and enabled required"])
                }
                DPPAdapterStore.shared.setEnabled(enabled, for: name)
                return try Self.json(["ok": true, "name": name, "enabled": enabled])
            case ("POST", "/dpp/adapters/remove"):
                guard let name = Self.string(body, "name") else {
                    return try Self.json(["error": "missing name"])
                }
                DPPAdapterStore.shared.remove(name)
                return try Self.json(["ok": true, "name": name])
            case ("POST", "/dpp/adapters/verify"):
                // 存活度核对（设计评审 #8 补全）：对每个启用的适配包，找当前打开的
                // 匹配标签页，跑一次真实抽取，报告各视图的元素命中数。
                var reports: [[String: Any]] = []
                for adapter in DPPAdapterStore.shared.adapters where DPPAdapterStore.shared.isEnabled(adapter) {
                    // 找打开的匹配标签（任意窗口）。
                    var target: Tab?
                    for m in TabSessionCoordinator.shared.liveManagers() {
                        if let t = m.tabs.first(where: { adapter.matches(url: $0.browser.webView.url ?? URL(fileURLWithPath: "/")) }) {
                            target = t
                            break
                        }
                    }
                    guard let tab = target else {
                        reports.append(["name": adapter.name, "status": "no matching tab open"])
                        continue
                    }
                    var viewReports: [[String: Any]] = []
                    for kv in adapter.protocolBody.views.sorted(by: { $0.key < $1.key }) {
                        // 元素计数：evaluateJavaScript 同步返回（-1 = 选择器抛错/跨边界不可达）。
                        let js = "(function(){ try { return document.querySelectorAll(\(JSString.literal(kv.value.item))).length; } catch(e) { return -1; } })()"
                        let count = (try? await tab.browser.webView.evaluateJavaScript(js)) as? Int ?? -1
                        viewReports.append(["view": kv.key, "item": kv.value.item, "elements": count])
                    }
                    let hitViews = viewReports.filter { ($0["elements"] as? Int ?? 0) > 0 }.count
                    reports.append([
                        "name": adapter.name,
                        "status": hitViews > 0 ? "alive" : "rotten",
                        "tab": tab.browser.webView.url?.absoluteString ?? "",
                        "views": viewReports,
                    ])
                }
                return try Self.json(["reports": reports])
            case ("GET", "/page/extract"):
                // 与 agent 的 pageExtract **同一实现**（BrowserToolProvider.execute），
                // 只读无审批面——适配包自测的主通道。
                guard let provider = Self.dppToolProvider() else {
                    return try Self.json(["error": "no live agent session"])
                }
                guard let view = Self.string(query, "view"),
                      let toolWebView = Self.dppWebViewForTools() else {
                    return try Self.json(["error": "missing view or no active tab"])
                }
                let argsJSON = Self.toolArgsJSON(["view": view, "all": query["all"] == "1"])
                let call = AgentToolCall(
                    id: UUID().uuidString, type: "function",
                    function: .init(name: "pageExtract", arguments: argsJSON))
                let result = await provider.execute(call, in: toolWebView)
                return try Self.json(["view": view, "result": result])
            case ("POST", "/page/dpp-action"):
                // 与 agent 的 pageAction 同一实现；**只放行 local 效果动作**——
                // persist/outbound 的真实执行必须走 agent 审批链（桥不替代用户授权）。
                guard let provider = Self.dppToolProvider() else {
                    return try Self.json(["error": "no live agent session"])
                }
                guard let name = Self.string(body, "name"),
                      let toolWebView = Self.dppWebViewForTools() else {
                    return try Self.json(["error": "missing name or no active tab"])
                }
                guard let action = TabSessionCoordinator.shared.activeTabManager?.selectedTab?.browser.effectiveProtocol?.actions.first(where: { $0.name == name }),
                      action.isBridgeSafeLocal else {
                    return try Self.json(["error": "DPP action requires Agent approval; run it from the Agent session"])
                }
                let args = body["args"] as? [String: Any] ?? [:]
                let call = AgentToolCall(
                    id: UUID().uuidString, type: "function",
                    function: .init(name: "pageAction",
                                    arguments: Self.toolArgsJSON(["name": name, "args": args])))
                let result = await provider.execute(call, in: toolWebView)
                return try Self.json(["action": name, "result": result])
            case ("GET", "/agent/approvals"):
                guard let pending = AgentScheduler.shared.deliveryTarget?.pendingApproval else {
                    return try Self.json(["pending": false])
                }
                return try Self.json([
                    "pending": true,
                    "tool": pending.toolCall.function.name,
                    "arguments": pending.argumentsSummary,
                    "risk": pending.risk.displayName,
                ])
            case ("POST", "/agent/approvals/resolve"):
                guard let decision = Self.string(body, "decision") else {
                    return try Self.json(["error": "missing decision"])
                }
                let outcome: ApprovalDecision
                switch decision {
                case "allowOnce": outcome = .allowOnce
                case "alwaysAllow": outcome = .alwaysAllow
                case "deny": outcome = .deny
                default:
                    return try Self.json(["error": "decision must be allowOnce|alwaysAllow|deny"])
                }
                guard let pending = AgentScheduler.shared.deliveryTarget?.pendingApproval else {
                    return try Self.json(["error": "no pending approval"])
                }
                AgentScheduler.shared.deliveryTarget?.resolveApproval(outcome)
                return try Self.json(["ok": true, "tool": pending.toolCall.function.name, "decision": decision])
            case ("GET", "/dpp/action-approvals"):
                // DPP 逐动作放行清单（0.6.7）：host × action 的用户授权。
                return try Self.json([
                    "rules": DPPActionApprovals.shared.all().map { r in
                        ["id": r.id.uuidString, "host": r.host, "action": r.actionName]
                    }
                ])
            case ("POST", "/dpp/action-approvals/allow"):
                guard let host = Self.string(body, "host"), let action = Self.string(body, "action") else {
                    return try Self.json(["error": "host and action required"])
                }
                DPPActionApprovals.shared.allow(host: host, frameHost: nil, actionName: action)
                return try Self.json(["ok": true, "host": host, "action": action])
            case ("POST", "/dpp/action-approvals/revoke"):
                if let ruleID = Self.string(body, "id").flatMap(UUID.init) {
                    DPPActionApprovals.shared.revoke(ruleID: ruleID)
                } else if let host = Self.string(body, "host"), let action = Self.string(body, "action") {
                    DPPActionApprovals.shared.revoke(host: host, frameHost: nil, actionName: action)
                } else {
                    return try Self.json(["error": "id or host+action required"])
                }
                return try Self.json(["ok": true])
            case ("GET", "/downloads/dangerous"):
                let tm = try tabManager
                if let pending = tm?.selectedTab?.browser.pendingDangerousDownload {
                    return try Self.json(["pending": ["url": pending.url.absoluteString, "filename": pending.filename]])
                }
                return try Self.json(["pending": NSNull()])
            case ("POST", "/downloads/dangerous/resolve"):
                let tm = try tabManager
                guard let pending = tm?.selectedTab?.browser.pendingDangerousDownload else {
                    return try Self.json(["error": "no pending dangerous-download confirmation"])
                }
                let allow = body["allow"] as? Bool ?? false
                pending.respond(allow)
                return try Self.json(["ok": true, "allow": allow])
            case ("POST", "/passwords/add"):
                return try Self.json(Self.addPassword(domain: Self.string(body, "domain") ?? "",
                                                      username: Self.string(body, "username") ?? "",
                                                      password: Self.string(body, "password") ?? ""))
            case ("POST", "/passwords/import"):
                return try Self.json(Self.importPasswordCSV(Self.string(body, "csv") ?? ""))
            case ("POST", "/passwords/resolve"):
                return try Self.json(Self.resolvePasswordSave(body["save"] as? Bool ?? true))
            case ("POST", "/passwords/delete"):
                return try Self.json(Self.deletePasswords(
                    domain: Self.string(body, "domain") ?? "",
                    username: Self.string(body, "username")))
            case ("GET", "/import/browsers"):
                return try Self.json(Self.importBrowsers())
            case ("POST", "/import/preview"):
                return try Self.json(Self.importPreview(path: Self.string(body, "path") ?? ""))
            case ("POST", "/import/run"):
                return try Self.json(Self.importRun(body: body))
            case ("GET", "/webapps"):
                return try Self.json(Self.webApps())
            case ("POST", "/webapps/add"):
                return try Self.json(Self.addWebApp(body: body))
            case ("POST", "/webapps/open"):
                return try Self.json(Self.openWebApp(id: Self.string(body, "id") ?? ""))
            case ("POST", "/webapps/delete"):
                return try Self.json(Self.deleteWebApp(id: Self.string(body, "id") ?? ""))
            case ("POST", "/containers/remove"):
                return try Self.json(Self.removeContainer(Self.string(body, "name") ?? ""))
            case ("GET", "/site-settings"):
                return try Self.json(Self.siteSettings(host: Self.string(query, "host") ?? ""))
            case ("POST", "/site-settings/darkmode"):
                return try Self.json(Self.setSiteDarkMode(
                    host: Self.string(body, "host") ?? "",
                    enabled: body["enabled"] as? Bool ?? false
                ))
            case ("POST", "/site-settings/zoom"):
                return try Self.json(Self.setSiteZoom(
                    host: Self.string(body, "host") ?? "",
                    zoom: body["zoom"] as? Double ?? 1.0
                ))
            case ("POST", "/site-settings/font"):
                return try Self.json(Self.setSiteFont(body: body))
            case ("POST", "/site-settings/autoplay"):
                return try Self.json(Self.setSiteAutoPlay(body: body))
            case ("POST", "/site-settings/clear"):
                return try Self.json(Self.clearSiteSettings(host: Self.string(body, "host") ?? ""))
            case ("GET", "/palette"):
                return try Self.json(Self.palette(query: Self.string(query, "q") ?? ""))
            case ("GET", "/agent/weekly-digest"):
                return try Self.json(Self.weeklyDigestState())
            case ("POST", "/agent/weekly-digest"):
                return try Self.json(await Self.weeklyDigestAction(
                    action: Self.string(body, "action") ?? "run-now",
                    writeToNotes: body["writeToNotes"] as? Bool ?? false,
                    conversationId: Self.string(body, "conversationId")))
            case ("GET", "/agent/rule-draft"):
                return try Self.json(Self.agentRuleDraft(
                    conversation: Self.string(query, "conversation"),
                    turn: Int(Self.string(query, "turn") ?? "")))
            case ("GET", "/agent/find"):
                return try Self.json(Self.agentMessageFind(
                    query: Self.string(query, "q") ?? "",
                    window: Self.string(query, "window")))
            case ("GET", "/bilingual"):
                return try Self.json(Self.bilingualState())
            case ("POST", "/bilingual"):
                return try Self.json(Self.setBilingual(
                    on: body["on"] as? Bool ?? false,
                    index: Self.index(body)))
            case ("GET", "/quickdial"):
                return try Self.json(Self.quickDial())
            case ("POST", "/quickdial/add"):
                return try Self.json(Self.addQuickDial(
                    title: Self.string(body, "title") ?? "",
                    url: Self.string(body, "url") ?? ""
                ))
            case ("POST", "/quickdial/delete"):
                return try Self.json(Self.deleteQuickDial(url: Self.string(body, "url") ?? ""))
            case ("GET", "/suggest"):
                return try Self.json(Self.suggest(query: Self.string(query, "q") ?? ""))
            case ("GET", "/agent/stats"):
                return try Self.json(Self.usageStats(
                    days: Int(Self.string(query, "days") ?? "")))
            case ("GET", "/agent/trace"):
                return try Self.json(Self.agentTrace(
                    conversation: Self.string(query, "conversation"),
                    limit: Int(Self.string(query, "limit") ?? "")))
            case ("GET", "/conversations"):
                return try Self.json(Self.conversationsList(
                    limit: Self.string(query, "limit").flatMap { Int($0) } ?? 20))
            case ("GET", "/windows"):
                return try Self.json(Self.windowsList())
            case ("GET", "/conversations/search"):
                return try Self.json(Self.searchConversations(
                    query: Self.string(query, "q") ?? "",
                    limit: Int(Self.string(query, "limit") ?? "") ?? 5))
            case ("POST", "/bookmarks/add"):
                return try Self.json(Self.addBookmark(
                    title: Self.string(body, "title") ?? "",
                    url: Self.string(body, "url") ?? ""
                ))
            case ("POST", "/bookmarks/remove"):
                if let id = UUID(uuidString: Self.string(body, "id") ?? "") {
                    return try Self.json(Self.removeBookmark(id: id))
                }
                return try Self.json(Self.removeBookmark(url: Self.string(body, "url") ?? ""))
            case ("POST", "/bookmarks/import"):
                return try Self.json(Self.importBookmarksBridge(
                    html: Self.string(body, "html"),
                    path: Self.string(body, "path"),
                    strategy: Self.string(body, "strategy") ?? "skipDuplicates",
                    dryRun: body["dryRun"] as? Bool ?? false))
            case ("GET", "/bookmarks/health"):
                let checker = BookmarkLinkChecker.shared
                return try Self.json([
                    "running": checker.isRunning,
                    "total": checker.total,
                    "checked": checker.checked,
                    "dead": checker.dead.map { ["title": $0.title, "url": $0.url, "reason": $0.reason] },
                    "redirected": checker.redirected.map { ["title": $0.title, "url": $0.url, "to": $0.destination] },
                    "lastReportAt": checker.lastReportAt?.timeIntervalSince1970 ?? 0,
                ])
            case ("POST", "/bookmarks/health/cleanup"):
                return try Self.json(Self.bookmarkHealthCleanup(urls: body["urls"] as? [String] ?? []))
            case ("POST", "/bookmarks/health/check"):
                guard let hlSession = Self.resolveSession(Self.string(body, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                guard let hlApp = AppState.live else {
                    return try Self.json(["error": "app state not ready"])
                }
                let hlQueued = BookmarkLinkChecker.shared.start(
                    store: hlApp.bookmarkStore,
                    urls: (body["urls"] as? [String]) ?? [],
                    limit: min(500, max(1, (body["limit"] as? Int) ?? 100)),
                    session: hlSession)
                return try Self.json(["ok": true, "queued": hlQueued,
                                      "running": BookmarkLinkChecker.shared.isRunning])
            case ("POST", "/tabs/pin"):
                return try Self.json(Self.setPin(index: Self.index(body), pinned: body["pinned"] as? Bool))
            case ("GET", "/reading-list"):
                return try Self.json(Self.readingList())
            case ("POST", "/reading-list/progress"):
                return try Self.json(Self.setReadingProgress(
                    url: Self.string(body, "url") ?? "",
                    ratio: body["ratio"] as? Double ?? 0))
            case ("GET", "/workspaces"):
                return try Self.json(Self.workspacesList())
            case ("POST", "/inbox/dismiss"):
                return try Self.json(Self.inboxDismiss(body: body))
            case ("POST", "/inbox/batch"):
                return try Self.json(Self.inboxBatch(body: body))
            case ("POST", "/inbox/restore"):
                return try Self.json(Self.inboxRestore(ids: body["ids"] as? [String]))
            case ("POST", "/agent/eval-export"):
                return try Self.json(Self.evalExport(path: Self.string(body, "path")))
            case ("GET", "/agent/eval-exports"):
                return try Self.json(Self.evalExportsList())
            case ("POST", "/agent/eval-export/delete"):
                return try Self.json(Self.evalExportDelete(path: Self.string(body, "path") ?? ""))
            case ("POST", "/agent/eval-fixture/register"):
                return try Self.json(Self.evalFixtureRegister(path: Self.string(body, "path")))
            case ("GET", "/agent/eval-fixtures"):
                return try Self.json(Self.evalFixturesList())
            case ("POST", "/agent/eval-fixture/delete"):
                return try Self.json(Self.evalFixtureDelete(path: Self.string(body, "path") ?? ""))
            case ("GET", "/crew"):
                return try Self.json(Self.crewState())
            case ("POST", "/crew"):
                return try Self.json(Self.crewAction(Self.string(body, "action") ?? "clear"))
            case ("GET", "/inbox"):
                return try Self.json(Self.agentInbox())
            case ("GET", "/speech"):
                return try Self.json(Self.speechState())
            case ("POST", "/speech/stop"):
                ReaderSpeechService.shared.stop()
                return try Self.json(Self.speechState())
            case ("GET", "/agent/budget"):
                return try Self.json(Self.agentBudget(window: Self.string(query, "window")))
            case ("POST", "/agent/budget"):
                guard let tokens = body["tokens"] as? Int else {
                    return try Self.json(["error": "tokens required (int; 0 = off)"])
                }
                guard let session = Self.resolveSession(Self.string(body, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                session.setTokenBudget(tokens)
                return try Self.json(session.budgetSnapshot())
            case ("GET", "/session-archives"):
                return try Self.json(Self.sessionArchivesList())
            case ("POST", "/session-archives/restore"):
                return try Self.json(Self.sessionArchiveRestore(
                    file: Self.string(body, "file") ?? "",
                    window: Self.string(body, "window")))
            case ("POST", "/session-archives/delete"):
                return try Self.json(Self.sessionArchiveDelete(file: Self.string(body, "file") ?? ""))
            case ("GET", "/tab-groups"):
                return try Self.json(Self.tabGroupsList())
            case ("POST", "/tab-groups/delete"):
                return try Self.json(Self.tabGroupDelete(name: Self.string(body, "name") ?? ""))
            case ("POST", "/workspaces/delete"):
                return try Self.json(Self.workspaceDelete(name: Self.string(body, "name") ?? ""))
            case ("GET", "/system/integrations"):
                return try Self.json([
                    "reminders": EventKitBridge.access(.reminder).rawValue,
                    "calendar": EventKitBridge.access(.event).rawValue,
                ])
            case ("POST", "/reading-list/cache"):
                return try await Self.json(Self.readingListCacheAsync(url: Self.string(body, "url") ?? ""))
            case ("POST", "/reading-list/add"):
                return try Self.json(Self.addReadingItem(
                    title: Self.string(body, "title") ?? "",
                    url: Self.string(body, "url") ?? ""
                ))
            case ("POST", "/reading-list/remove"):
                return try Self.json(Self.removeReadingItem(url: Self.string(body, "url") ?? ""))
            case ("POST", "/reading-list/summarize"):
                guard let rlSession = Self.resolveSession(Self.string(body, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                guard let rlApp = AppState.live else {
                    return try Self.json(["error": "app state not ready"])
                }
                let rlURLs = (body["urls"] as? [String]) ?? []
                let rlStarted = ReadingListSummarizer.shared.start(
                    store: rlApp.readingListStore,
                    preference: rlSession.preference,
                    limit: min(20, max(1, (body["limit"] as? Int) ?? 5)),
                    force: (body["force"] as? Bool) ?? false,
                    urls: rlURLs,
                    session: rlSession)
                return try Self.json(["ok": true, "queued": rlStarted,
                                      "running": ReadingListSummarizer.shared.isRunning])
            case ("GET", "/sync/devices"):
                guard let store = AppState.live?.syncStore else { return try Self.json(["error": "app state not ready"]) }
                await store.refreshDevices()
                return try Self.json(["ok": store.devicesError == nil,
                                      "error": store.devicesError ?? "",
                                      "devices": store.devices.map { device in
                                          ["device_id": device.deviceID, "name": device.name,
                                           "platform": device.platform, "revoked": device.revoked,
                                           "last_seen_at": device.lastSeenAt?.timeIntervalSince1970 ?? 0,
                                           "cursor_seen_at": device.cursorSeenAt?.timeIntervalSince1970 ?? 0] as [String: Any]
                                      }])
            case ("GET", "/sync/conflicts"):
                return try Self.json(Self.syncConflicts())
            case ("POST", "/sync/conflicts/clear"):
                AppState.live?.syncStore.clearConflictNotes()
                return try Self.json(Self.syncConflicts())
            case ("GET", "/sync/status"):
                return try Self.json(Self.syncStatus())
            case ("POST", "/sync/now"):
                return try Self.json(await Self.syncNowBridge())
            case ("POST", "/sync/login"):
                return try Self.json(await Self.syncAuth(body, register: false))
            case ("POST", "/sync/register"):
                return try Self.json(await Self.syncAuth(body, register: true))
            case ("POST", "/sync/logout"):
                return try Self.json(Self.syncLogout())
            case ("POST", "/sync/server"):
                return try Self.json(Self.syncSetServer(Self.string(body, "baseURL") ?? ""))
            case ("POST", "/remote/toggle"):
                return try Self.json(Self.remoteToggle(body["enabled"] as? Bool ?? false))
            case ("POST", "/remote/pair"):
                return try Self.json(Self.remotePairStart())
            case ("GET", "/remote/sessions-frame"):
                return try Self.json(Self.remoteSessionsFrame())
            case ("POST", "/remote/mark-seen"):
                AppState.live?.remoteControlStore.markRemoteSeen(Self.string(body, "conversationId"))
                return try Self.json(["ok": true])
            case ("GET", "/history/archive-search"):
                // 归档历史检索（v0.7.25）：服务端存密文——客户端全量拉取+本地解密。
                return try Self.json(await Self.historyArchiveSearch(
                    query: Self.string(query, "q") ?? "",
                    limit: Int(Self.string(query, "limit") ?? "") ?? 50))
            case ("POST", "/agent/daily-brief"):
                // 每日简报（v0.7.25）：确定性派生（今日会话/用量/收件箱/记忆）→
                // 会话备注 + routine 通知（可选上板）。
                return try Self.json(Self.dailyBriefRun(
                    toBoard: body["toBoard"] as? Bool))
            case ("POST", "/selection/assist"):
                // 划词就地卡（v0.7.25 旗舰）：旁路流式一次（不产生会话消息）。
                return try Self.json(await Self.selectionAssist(
                    text: Self.string(body, "text") ?? "",
                    mode: Self.string(body, "mode") ?? "auto"))
            case ("GET", "/board/gallery"):
                return try Self.json(await Self.boardGalleryList(base: Self.string(query, "baseURL")))
            case ("POST", "/board/gallery/import"):
                return try Self.json(await Self.boardGalleryImport(
                    id: Self.string(body, "id") ?? "",
                    mode: Self.string(body, "mode") ?? "auto",
                    base: Self.string(body, "baseURL"),
                    conversationId: Self.string(body, "conversationId")))
            case ("POST", "/share-card"):
                // 网页分享卡（v0.7.24）：活跃标签 → 首屏图 + 标题/域名 +
                //（可选）旁路模型摘要 → PNG 存下载目录。
                return try Self.json(await Self.pageShareCard(
                    index: Self.index(body),
                    summarize: body["summarize"] as? Bool ?? true))
            case ("GET", "/remote/board-payload"):
                return try Self.json(Self.remoteBoardPayload(
                    conversationId: Self.string(query, "conversationId")))
            case ("GET", "/remote/status"):
                return try Self.json(Self.remoteStatus())
            case ("POST", "/sync/setting"):
                return try Self.json(Self.syncSetSetting(body))
            case ("POST", "/sync/domain"):
                return try Self.json(Self.syncSetDomain(body))
            case ("GET", "/search-history"):
                return try Self.json(Self.searchHistory(count: Int(query["count"] ?? "10") ?? 10))
            case ("POST", "/search-history/add"):
                return try Self.json(Self.addSearchHistory(
                    query: Self.string(body, "query") ?? "",
                    engine: Self.string(body, "engine") ?? "google"
                ))
            case ("POST", "/search-history/clear"):
                return try Self.json(Self.clearSearchHistory())
            case ("GET", "/tabgroups"):
                return try Self.json(Self.tabGroups())
            case ("POST", "/tabgroups/create"):
                return try Self.json(Self.createTabGroup(
                    name: Self.string(body, "name") ?? "",
                    tabIndex: Self.index(body)
                ))
            case ("POST", "/tabgroups/collapse"):
                return try Self.json(Self.collapseTabGroup(
                    name: Self.string(body, "name") ?? "",
                    collapsed: body["collapsed"] as? Bool ?? true
                ))
            case ("POST", "/tabgroups/delete"):
                return try Self.json(Self.deleteTabGroup(name: Self.string(body, "name") ?? ""))
            case ("POST", "/tabgroups/organize"):
                return try Self.json(Self.organizeTabGroups())
            case ("POST", "/tabgroups/undo"):
                return try Self.json(Self.undoTabGroups())
            case ("GET", "/elements"):
                return try Self.json(Self.elementRules())
            case ("POST", "/elements/add"):
                return try Self.json(Self.addElementRule(
                    selector: Self.string(body, "selector") ?? "",
                    pattern: Self.string(body, "pattern") ?? ""
                ))
            case ("POST", "/elements/remove"):
                return try Self.json(Self.removeElementRule(
                    pattern: Self.string(body, "pattern") ?? "",
                    selector: Self.string(body, "selector") ?? ""
                ))
            case ("GET", "/annotations"):
                let tm2 = try tabManager
                guard let tab2 = tm2?.selectedTab,
                      let url = tab2.browser.webView.url?.absoluteString else {
                    return try Self.json(["highlights": [] as [[String: Any]]])
                }
                let highlights: [[String: Any]] = AnnotationStore.shared.highlights(for: url).map { h in
                    ["id": h.id.uuidString, "text": h.text,
                     "color": AnnotationStore.palette[min(h.colorIndex, AnnotationStore.palette.count - 1)]]
                }
                return try Self.json(["url": url, "highlights": highlights])
            case ("GET", "/shortcuts"):
                return try Self.json(Self.shortcuts())
            case ("POST", "/shortcuts/update"):
                return try Self.json(Self.updateShortcut(
                    id: Self.string(body, "id") ?? "",
                    key: Self.string(body, "key") ?? "",
                    modifierFlags: body["modifierFlags"] as? UInt ?? NSEvent.ModifierFlags.command.rawValue
                ))            case ("POST", "/beforeunload/resolve"):
                return try Self.json(Self.resolveBeforeUnload(
                    index: Self.index(body),
                    leave: body["leave"] as? Bool ?? true
                ))
            case ("POST", "/approvals/resolve"):
                return try Self.json(Self.resolvePendingApproval(
                    Self.string(body, "decision") ?? "",
                    window: Self.string(body, "window"),
                    siteGrant: body["siteGrant"] as? Bool ?? false
                ))
            case ("POST", "/devtools/eval"):
                return try await Self.json(Self.devToolsEval(js: Self.string(body, "js") ?? "", index: Self.index(body)))
            case ("POST", "/devtools/inspect"):
                return try await Self.json(Self.devToolsInspect(selector: Self.string(body, "selector") ?? "", index: Self.index(body)))
            case ("GET", "/devtools"):
                return try Self.json(Self.devToolsState())
            case ("GET", "/devtools/har"):
                // HAR 1.2 导出（0.7.5）：作用域与面板同源（TabScope）。
                // ?scope=all|current|tab=<uuid>，缺省 = 当前面板作用域。
                let store = AppState.live?.devToolsStore
                let scopeParam = query["scope"]
                let requests: [NetworkRequest]
                switch scopeParam {
                case "all":
                    requests = store?.networkRequests ?? []
                case "current":
                    requests = store?.scopedNetworkRequests ?? []
                case .some(let v) where v.hasPrefix("tab="):
                    guard let id = UUID(uuidString: String(v.dropFirst(4))) else {
                        return try Self.json(["error": "bad tab uuid"])
                    }
                    requests = (store?.networkRequests ?? []).filter { $0.tabID == id }
                default:
                    requests = store?.scopedNetworkRequests ?? []
                }
                guard let json = HARExport.jsonString(from: requests) else {
                    return try Self.json(["error": "har serialization failed"])
                }
                return json
            case ("POST", "/devtools/edit"):
                return try await Self.json(Self.devToolsEdit(
                    selector: Self.string(body, "selector") ?? "",
                    style: body["style"] as? [String: String] ?? [:],
                    attributes: body["attributes"] as? [String: String] ?? [:],
                    index: Self.index(body)
                ))
            case ("GET", "/ai/profiles"):
                return try Self.json(Self.aiProfiles())
            case ("POST", "/ai/profiles"):
                return try Self.json(Self.aiProfileUpsert(
                    id: Self.string(body, "id"),
                    name: Self.string(body, "name") ?? "",
                    endpoint: Self.string(body, "endpoint") ?? "",
                    model: Self.string(body, "model") ?? "",
                    models: (body["models"] as? [String]) ?? [],
                    headers: (body["headers"] as? [String: String]) ?? [:],
                    key: Self.string(body, "key"),
                    apiFormat: Self.string(body, "apiFormat")
                ))
            case ("POST", "/ai/models/fetch"):
                return try await Self.json(Self.aiFetchModels(id: Self.string(body, "id")))
            case ("POST", "/ai/model"):
                return try Self.json(Self.aiSetModel(Self.string(body, "model") ?? ""))
            case ("POST", "/ai/profiles/activate"):
                return try Self.json(Self.aiProfileActivate(id: Self.string(body, "id") ?? ""))
            case ("GET", "/agent/cost-breakdown"):
                // 本对话成本明细（v0.7.26）：模型×类型拆组 + 合计（AgentUsage 口径）。
                guard let session = Self.resolveSession(Self.string(query, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                let price = AppState.live?.aiPreference.usagePrice(for:) ?? { _ in nil }
                let result = CostBreakdown.derive(session.messages, price: price)
                return try Self.json([
                    "groups": result.groups.map { group -> [String: Any] in
                        ["category": group.category,
                         "kind": group.kind ?? "",
                         "model": group.model ?? "",
                         "promptTokens": group.promptTokens,
                         "completionTokens": group.completionTokens,
                         "usd": group.usd.map { $0 as Any } ?? NSNull()]
                    },
                    "totalTokens": result.usage.totalTokens,
                    "usd": result.usage.usd.map { $0 as Any } ?? NSNull(),
                    "hasUnpriced": result.usage.hasUnpriced,
                ])
            case ("GET", "/ai/routing"):
                guard let pref = AppState.live?.aiPreference else { return try Self.json(["error": "preference not ready"]) }
                return try Self.json([
                    "enabled": pref.costAwareRouting,
                    "providerKind": pref.providerKind.rawValue,
                    "lockedToCloud": pref.routingLockedToCloud,
                    "lastProviderUsed": AgentScheduler.shared.deliveryTarget?.lastProviderUsed ?? NSNull(),
                ])
            case ("POST", "/ai/routing"):
                guard let pref = AppState.live?.aiPreference else { return try Self.json(["error": "preference not ready"]) }
                pref.costAwareRouting = body["enabled"] as? Bool ?? false
                return try Self.json(["ok": true, "enabled": pref.costAwareRouting])
            case ("GET", "/ai/bypass-profile"):
                guard let pref = AppState.live?.aiPreference else { return try Self.json(["error": "preference not ready"]) }
                var payload: [String: Any] = ["profileId": NSNull()]
                if let id = pref.bypassProfileID { payload["profileId"] = id.uuidString }
                return try Self.json(payload)
            case ("POST", "/ai/bypass-profile"):
                // 旁路调用（标题/记忆整理）走哪个档案；不带 id = 清除（跟随对话模型）。
                guard let pref = AppState.live?.aiPreference else { return try Self.json(["error": "preference not ready"]) }
                if let raw = Self.string(body, "id") {
                    guard let id = UUID(uuidString: raw), pref.profiles.contains(where: { $0.id == id }) else {
                        return try Self.json(["error": "unknown profile id"])
                    }
                    pref.bypassProfileID = id
                    return try Self.json(["ok": true, "profileId": raw])
                }
                pref.bypassProfileID = nil
                return try Self.json(["ok": true, "profileId": NSNull()])
            case ("GET", "/ai/fallback-profile"):
                guard let pref = AppState.live?.aiPreference else { return try Self.json(["error": "preference not ready"]) }
                var payload: [String: Any] = ["profileId": NSNull()]
                if let id = pref.fallbackProfileID { payload["profileId"] = id.uuidString }
                return try Self.json(payload)
            case ("POST", "/ai/fallback-profile"):
                // 备用档案（瞬态错误重试仍失败时的 failover 服务）；不带 id = 清除。
                guard let pref = AppState.live?.aiPreference else { return try Self.json(["error": "preference not ready"]) }
                if let raw = Self.string(body, "id") {
                    guard let id = UUID(uuidString: raw), pref.profiles.contains(where: { $0.id == id }) else {
                        return try Self.json(["error": "unknown profile id"])
                    }
                    pref.fallbackProfileID = id
                    return try Self.json(["ok": true, "profileId": raw])
                }
                pref.fallbackProfileID = nil
                return try Self.json(["ok": true, "profileId": NSNull()])
            case ("POST", "/ai/profiles/delete"):
                return try Self.json(Self.aiProfileDelete(id: Self.string(body, "id") ?? ""))
            case ("GET", "/ai/output-rules"):
                return try Self.json(Self.outputRulesList())
            case ("POST", "/ai/output-rules/add"):
                return try Self.json(Self.outputRulesAdd(text: Self.string(body, "text") ?? ""))
            case ("POST", "/ai/output-rules/remove"):
                return try Self.json(Self.outputRulesRemove(text: Self.string(body, "text") ?? ""))
            case ("GET", "/ai/prices"):
                return try Self.json(Self.aiPriceList())
            case ("POST", "/ai/prices"):
                return try Self.json(Self.aiPrices(
                    models: body["models"] as? [String: [String: Double]],
                    remove: body["remove"] as? [String]
                ))
            case ("GET", "/devtools/console/ref"):
                return try await Self.json(Self.devToolsConsoleRef(
                    ref: query["ref"] ?? "",
                    index: Self.index(query)
                ))
            case ("GET", "/devtools/tree"):
                return try await Self.json(Self.devToolsTree(
                    path: query["path"] ?? "",
                    index: Self.index(query)
                ))
            case ("POST", "/devtools/replay"):
                return try await Self.json(Self.devToolsReplay(
                    url: Self.string(body, "url") ?? "",
                    index: Self.index(body)
                ))
            case ("POST", "/devtools/preview"):
                return try await Self.json(Self.devToolsPreview(
                    url: Self.string(body, "url") ?? "",
                    index: Self.index(body)
                ))
            case ("POST", "/devtools/config"):
                // 调试面板的运行期开关（UserDefaults 在已运行的进程里读不到外部
                // 改动，E2E 直接改内存值最可靠）。
                guard let store = AppState.live?.devToolsStore else {
                    return Self.error("app state not ready")
                }
                if let clear = body["clearConsoleOnNavigate"] as? Bool {
                    store.clearConsoleOnNavigate = clear
                }
                if let section = Self.string(body, "applicationSection"),
                   let parsed = DevToolsStore.ApplicationSection(rawValue: section) {
                    store.applicationSection = parsed
                }
                // 标签页作用域：`current` / `all` / 某个标签页的 UUID。
                if let scope = Self.string(body, "tabScope") {
                    if let parsed = DevToolsStore.TabScope(bridgeValue: scope) {
                        store.tabScope = parsed
                    } else {
                        return Self.error("bad tabScope (use current | all | <tab uuid>)")
                    }
                }
                return try Self.json([
                    "clearConsoleOnNavigate": store.clearConsoleOnNavigate,
                    "applicationSection": store.applicationSection.rawValue,
                    "tabScope": store.tabScope.bridgeValue,
                    "devMode": store.isDevModeEnabled,
                    "panel": store.activePanel.rawValue,
                ])
            case ("GET", "/devtools/application"):
                return try await Self.json(Self.devToolsApplication(index: Self.index(query)))
            case ("POST", "/devtools/application/set"):
                return try await Self.json(Self.devToolsSetStorage(
                    kind: Self.string(body, "kind") ?? "",
                    key: Self.string(body, "key") ?? "",
                    value: Self.string(body, "value") ?? "",
                    extID: Self.string(body, "ext"),
                    domain: Self.string(body, "domain"),
                    index: Self.index(body)
                ))
            case ("POST", "/devtools/application/delete"):
                return try await Self.json(Self.devToolsDeleteStorage(
                    kind: Self.string(body, "kind") ?? "",
                    key: Self.string(body, "key"),
                    extID: Self.string(body, "ext"),
                    index: Self.index(body)
                ))
            case ("GET", "/rules"):
                return try Self.json(Self.videoAdRules())
            case ("POST", "/rules/refresh"):
                // 可选 {"trustRemoteJS": true|false} —— 等价于设置里的
                // "信任远程规则脚本"开关（脚本化验证信任门控用）。
                if let trusted = body["trustRemoteJS"] as? Bool {
                    VideoAdRulesStore.shared.setRemoteScriptsTrusted(trusted)
                }
                await VideoAdRulesStore.shared.reloadAll()
                return try Self.json(Self.videoAdRules())
            case ("GET", "/settings"):
                let st = Settings()
                return try Self.json([
                    "searchEngine": st.searchEngine.rawValue,
                    "httpsUpgradeEnabled": st.httpsUpgradeEnabled,
                    // 生效值（而非落盘的原始键）：旧安装里的 false 来自
                    // 2026-09-16 前的首次启动 bug，未显式选择过时按默认 ON。
                    "videoAdBlockerEnabled": VideoAdBlocker.resolvedEnabled,
                ])
            case ("POST", "/mcp/add"):
                // command 非空 = stdio 服务器（本地子进程）；否则 HTTP。
                if let command = Self.string(body, "command"), !command.isEmpty {
                    return try Self.json(Self.addMCPStdioServer(
                        name: Self.string(body, "name") ?? "", command: command))
                }
                return try Self.json(Self.addMCPServer(
                    name: Self.string(body, "name") ?? "",
                    url: Self.string(body, "url") ?? ""
                ))
            case ("POST", "/mcp/remove"):
                return try Self.json(Self.removeMCPServer(name: Self.string(body, "name") ?? ""))
            case ("POST", "/mcp/reconnect"):
                return try Self.json(Self.reconnectMCPServer(name: Self.string(body, "name") ?? ""))
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
                return try Self.json(["servers": servers, "tools": store.toolDefs.map(\.function.name), "prompts": store.allPrompts().count, "resources": store.allResources().count])
            case ("GET", "/downloads"):
                return try Self.json(Self.downloads())
            case ("POST", "/downloads/batch"):
                return try Self.json(Self.batchDownload(urls: body["urls"] as? [String] ?? []))
            case ("POST", "/downloads/start"):
                return try Self.json(Self.startDownload(Self.string(body, "url") ?? ""))
            case ("POST", "/downloads/remove"):
                // 从列表移除一条（"Remove from List" 同路径；磁盘文件不动）。
                guard let uuid = UUID(uuidString: Self.string(body, "id") ?? "") else {
                    return try Self.json(["error": "invalid id"])
                }
                DownloadStore.live?.remove(id: uuid)
                return try Self.json(["ok": true])
            case ("POST", "/downloads/pause"):
                return try Self.json(Self.pauseDownload(Self.string(body, "id")))
            case ("POST", "/downloads/resume"):
                return try Self.json(Self.resumeDownload(Self.string(body, "id")))
            case ("GET", "/downloads/scheduled"):
                return try Self.json(Self.scheduledDownloads())
            case ("POST", "/downloads/schedule"):
                return try Self.json(Self.scheduleDownload(body: body))
            case ("POST", "/downloads/scheduled/cancel"):
                return try Self.json(Self.cancelScheduledDownload(
                    id: Self.string(body, "id") ?? ""))
            case ("POST", "/execute"):
                return try await Self.json(Self.execute(
                    Self.string(body, "js") ?? "",
                    index: Self.index(body),
                    world: Self.string(body, "world") ?? "main"))
            case ("POST", "/panel"):
                return try Self.json(Self.panel(
                    name: Self.string(body, "name") ?? "",
                    show: body["show"] as? Bool,
                    tab: Self.string(body, "tab")
                ))
            case ("GET", "/panel/snapshot"):
                return try await Self.json(Self.panelSnapshot(
                    name: query["name"] ?? "downloads",
                    tab: query["tab"],
                    width: Self.string(query, "w").flatMap { Double($0) }.map { CGFloat($0) },
                    height: Self.string(query, "h").flatMap { Double($0) }.map { CGFloat($0) }
                ))
            case ("GET", "/bookmarks"):
                return try Self.json(Self.bookmarks(tree: (Self.string(query, "tree") ?? "") == "1"))
            case ("POST", "/command"):
                return try Self.json(Self.sendCommand(
                    name: Self.string(body, "name") ?? "",
                    index: body["index"] as? Int
                ))
            case ("GET", "/intercept"):
                return try Self.json(Self.interceptRules())
            case ("POST", "/intercept/add"):
                return try Self.json(Self.addInterceptRule(
                    urlFilter: Self.string(body, "urlFilter") ?? "",
                    kind: Self.string(body, "kind") ?? "block",
                    payload: Self.string(body, "payload")
                ))
            case ("POST", "/intercept/remove"):
                return try Self.json(Self.removeInterceptRule(id: Self.string(body, "id") ?? ""))
            case ("POST", "/intercept/record"):
                return try Self.json(Self.recordInterceptRules(
                    patternSubstring: Self.string(body, "pattern") ?? "",
                    limit: Int(query["limit"] ?? "20") ?? 20
                ))
            case ("POST", "/intercept/clear"):
                return try Self.json(Self.clearInterceptRules())
            case ("POST", "/intercept/session/add"):
                // 会话级动态规则（0.6.6）：不持久化，app 退出即消失；
                // networkRules 工具与 DevTools 的临时拦截走这里。
                guard let urlFilter = Self.string(body, "urlFilter"), !urlFilter.isEmpty else {
                    return try Self.json(["error": "urlFilter required"])
                }
                let kind = InterceptRule.Kind(rawValue: Self.string(body, "kind") ?? "block") ?? .block
                guard let rule = InterceptStore.shared.addSessionRule(
                    urlFilter: urlFilter, kind: kind, payload: Self.string(body, "payload")) else {
                    return try Self.json(["error": "invalid rule (redirect needs payload)"])
                }
                return try Self.json(["ok": true, "id": rule.id.uuidString, "session": true])
            case ("POST", "/intercept/session/clear"):
                InterceptStore.shared.clearSessionRules()
                return try Self.json(["ok": true, "cleared": "session"])
            case ("POST", "/extract"):
                return try await Self.json(Self.extract(
                    kind: Self.string(body, "kind") ?? "table",
                    selector: Self.string(body, "selector"),
                    format: Self.string(body, "format") ?? "json",
                    index: Self.index(body)
                ))
            case ("GET", "/media"):
                return try Self.json(Self.detectedMedia(index: Self.index(query)))
            case ("GET", "/media/variants"):
                return try await Self.json(Self.mediaVariants(
                    url: Self.string(query, "url") ?? "",
                    referer: Self.string(query, "referer")
                ))
            case ("POST", "/media/download"):
                return try Self.json(Self.downloadMedia(
                    url: Self.string(body, "url") ?? "",
                    referer: Self.string(body, "referer"),
                    fileNameHint: Self.string(body, "filename"),
                    maxBandwidth: body["maxBandwidth"] as? Int
                ))
            case ("POST", "/media/batch"):
                return try Self.json(Self.startMediaBatch(body: body))
            case ("GET", "/media/batch"):
                return try Self.json(Self.batchMediaSnapshot(id: Self.string(query, "id")))
            case ("POST", "/media/batch/cancel"):
                return try Self.json(Self.batchMediaCancel(id: Self.string(body, "id") ?? ""))
            case ("POST", "/media/batch/skip"):
                return try Self.json(Self.batchMediaSkip(
                    id: Self.string(body, "id") ?? "",
                    itemID: Self.string(body, "itemId") ?? ""
                ))
            case ("POST", "/media/batch/retry"):
                return try Self.json(Self.batchMediaRetry(id: Self.string(body, "id") ?? ""))
            case ("POST", "/media/batch/pause"):
                return try Self.json(Self.batchMediaPause(id: Self.string(body, "id") ?? "", paused: true))
            case ("POST", "/media/batch/resume"):
                return try Self.json(Self.batchMediaPause(id: Self.string(body, "id") ?? "", paused: false))
            case ("POST", "/media/batch/add"):
                return try Self.json(Self.batchMediaAdd(
                    id: Self.string(body, "id") ?? "",
                    urls: (body["urls"] as? [String]) ?? [],
                    kind: Self.string(body, "kind") ?? "list",
                    referer: Self.string(body, "referer")
                ))
            case ("GET", "/media/batch/log"):
                guard let id = Self.string(query, "id"), let uuid = UUID(uuidString: id) else {
                    return try Self.json(["error": "missing/invalid id"])
                }
                var lines = BatchMediaLogStore.entries(uuid).map { entry in
                    "\(Self.logTime(entry.at)) \(entry.line)"
                }
                if let tail = Self.string(query, "tail").flatMap({ Int($0) }), tail > 0, lines.count > tail {
                    lines = Array(lines.suffix(tail))
                }
                return try Self.json(["id": uuid.uuidString, "lines": lines])
            case ("GET", "/media/batch/history"):
                return try Self.json(Self.downloadHistory())
            case ("GET", "/media/batch/config"):
                return try Self.json(Self.batchMediaConfig())
            case ("POST", "/settings/section"):
                let raw = Self.string(body, "section") ?? ""
                guard let section = SettingsView.Section(rawValue: raw) else {
                    return try Self.json(["error": "unknown section; valid: \(SettingsView.Section.allCases.map(\.rawValue).joined(separator: "/"))"])
                }
                SettingsView.SettingsSectionNavigator.shared.selected = section
                _ = try? Self.sendCommand(name: "showSettings", index: nil)
                return try Self.json(["ok": true, "section": section.rawValue])
            case ("GET", "/notifications/policy"):
                let store = ProactiveNotificationStore.shared
                return try Self.json([
                    "ok": true,
                    "policy": Self.notificationPolicyJSON(store.policy),
                    "heldDigest": store.heldLines.count,
                    "routineDeliveredToday": store.routineDeliveredToday,
                ])
            case ("POST", "/notifications/policy"):
                let store = ProactiveNotificationStore.shared
                if let v = body["quietHoursEnabled"] as? Bool { store.policy.quietHoursEnabled = v }
                if let s = Self.string(body, "quietStart"),
                   let m = NotificationPolicy.minutesFromHHMM(s) { store.policy.quietStartMinute = m }
                if let s = Self.string(body, "quietEnd"),
                   let m = NotificationPolicy.minutesFromHHMM(s) { store.policy.quietEndMinute = m }
                if let v = body["dailyRoutineLimit"] as? Int { store.policy.dailyRoutineLimit = max(0, v) }
                return try Self.json([
                    "ok": true,
                    "policy": Self.notificationPolicyJSON(store.policy),
                ])
            case ("POST", "/notifications/test"):
                // 把一条测试通知推进分级闸（E2E）：返回它被扣下还是直推。
                guard let tier = NotificationTier(rawValue: Self.string(body, "tier") ?? "routine") else {
                    return try Self.json(["error": "tier must be routine|urgent"])
                }
                let store = ProactiveNotificationStore.shared
                let before = store.heldLines.count
                store.deliver(title: Self.string(body, "title") ?? "Test",
                              body: Self.string(body, "body") ?? "",
                              tier: tier)
                return try Self.json([
                    "ok": true,
                    "tier": tier.rawValue,
                    "held": store.heldLines.count > before,
                    "heldDigest": store.heldLines.count,
                ])
            case ("POST", "/notifications/flush"):
                let delivered = ProactiveNotificationStore.shared.flushDigest(force: true)
                return try Self.json(["ok": true, "delivered": delivered])
            case ("GET", "/ads/stats"):
                return try Self.json(Self.adBlockStats())
            case ("POST", "/app/quit"):
                // 优雅退出（与 Cmd+Q 同路径：applicationShouldTerminate → flush）。
                // 测试收尾用，替代 shell 里的 pkill（强杀会丢防抖写盘窗口）。
                NSApp.terminate(nil)
                return try Self.json(["ok": true, "quitting": true])
            case ("POST", "/ads/stats/clear"):
                AdBlockStatsStore.shared.clear()
                return try Self.json(["ok": true])
            case ("POST", "/media/batch/manage"):
                return try Self.json(Self.batchManage(body: body))
            case ("POST", "/media/batch/config"):
                return try Self.json(Self.setBatchMediaConfig(body: body))
            case ("GET", "/profiles"):
                return try Self.json(Self.profiles())
            case ("GET", "/split"):
                let tm = try tabManager
                var state: [String: Any] = ["selected": tm?.selectedIndex ?? -1]
                if let partner = tm?.splitPartnerIndex {
                    state["partner"] = partner
                } else {
                    state["partner"] = NSNull()
                }
                return try Self.json(state)
            case ("POST", "/split"):
                let tm = try tabManager
                guard let tm else { return try Self.json(["error": "no tab manager"]) }
                guard let index = body["index"] as? Int, tm.tabs.indices.contains(index) else {
                    return try Self.json(["error": "missing/invalid index"])
                }
                tm.setSplitPartner(at: index)
                var result: [String: Any] = ["ok": true]
                if let partner = tm.splitPartnerIndex {
                    result["partner"] = partner
                } else {
                    result["partner"] = NSNull()
                }
                return try Self.json(result)
            case ("POST", "/split/close"):
                try tabManager?.setSplitPartner(at: nil)
                return try Self.json(["ok": true, "partner": NSNull()])
            case ("POST", "/profiles/add"):
                return try Self.json(Self.addProfile(name: Self.string(body, "name") ?? ""))
            case ("GET", "/profiles/active"):
                let tm = try? tabManager
                return try Self.json(["profileDataStore": tm?.profileDataStore != nil ? "custom" : "default"])
            case ("POST", "/profiles/active"):
                return try Self.json(setActiveProfile(name: Self.string(body, "name") ?? ""))
            case ("POST", "/profiles/remove"):
                return try Self.json(Self.removeProfile(name: Self.string(body, "name") ?? ""))
            case ("GET", "/watches"):
                return try Self.json(Self.listWatches())
            case ("POST", "/watches/add"):
                return try Self.json(Self.addWatch(
                    name: Self.string(body, "name") ?? "",
                    url: Self.string(body, "url") ?? "",
                    selector: Self.string(body, "selector"),
                    minutes: body["minutes"] as? Int ?? 5,
                    aiAnalysis: body["aiAnalysis"] as? Bool,
                    numericSelector: Self.string(body, "numericSelector"),
                    alertAbove: body["alertAbove"] as? Double,
                    alertBelow: body["alertBelow"] as? Double
                ))
            case ("POST", "/watches/remove"):
                return try Self.json(Self.removeWatch(name: Self.string(body, "name") ?? ""))
            case ("POST", "/watches/enable"):
                return try Self.json(Self.setWatchEnabled(
                    name: Self.string(body, "name") ?? "",
                    enabled: body["enabled"] as? Bool
                ))
            case ("POST", "/watches/check"):
                return try await Self.json(Self.checkWatch(name: Self.string(body, "name") ?? ""))
            case ("POST", "/agent/handoff"):
                // 会话接力（v0.7.25）：把当前投递会话的对话交给另一窗口接管。
                return try Self.json(Self.agentHandoff(window: Self.string(body, "window")))
            case ("GET", "/agent/windows"):
                return try Self.json(Self.agentWindows())
            case ("GET", "/agent/messages"):
                return try Self.json(Self.agentMessages(window: Self.string(query, "window")))
            case ("POST", "/update/install"):
                UpdateChecker.shared.startCheckThenInstall()
                return try Self.json(["ok": true, "started": true])
            case ("POST", "/agent/new"):
                // 开新会话（面板"新对话"按钮同路径：store.clear()——旧会话
                // 文件不动）。E2E/自动化从这里拿干净的会话。
                guard let session = Self.resolveSession(Self.string(body, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                session.clear()
                return try Self.json(["ok": true])
            case ("POST", "/agent/resume"):
                // 检查点恢复：继续被打断的回合 / 放弃（清标志）。
                let action = Self.string(body, "action") ?? "resume"
                guard let session = Self.resolveSession(Self.string(body, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                switch action {
                case "resume":
                    let ok = session.resumeInterruptedTurn()
                    return try Self.json(["ok": ok, "busy": session.isProcessing,
                                          "hasInterruptedTurn": session.hasInterruptedTurn])
                case "discard":
                    session.discardInterruptedTurn()
                    return try Self.json(["ok": true, "hasInterruptedTurn": session.hasInterruptedTurn])
                default:
                    return try Self.json(["error": "action must be resume or discard"])
                }
            case ("POST", "/agent/open"):
                // 装载指定会话到活跃 Agent 面板（强杀后恢复：中断的会话未必是
                // 面板自动还原的那个，先 open 再 resume）。
                guard let session = Self.resolveSession(Self.string(body, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                guard let idString = Self.string(body, "conversationId"),
                      let id = UUID(uuidString: idString) else {
                    return try Self.json(["error": "conversationId required"])
                }
                session.loadConversation(id)
                return try Self.json([
                    "ok": true,
                    "messages": session.messages.count,
                    "hasInterruptedTurn": session.hasInterruptedTurn,
                ])
            case ("GET", "/ads/rules"):
                return try Self.json(Self.adRules(host: Self.string(body, "host") ?? Self.string(query, "host")))
            case ("POST", "/ads/rules/clear"):
                return try Self.json(Self.adRulesClear(host: Self.string(body, "host")))
            case ("GET", "/ads/candidates"):
                return try await Self.json(Self.adCandidates(index: Self.index(query)))
            case ("POST", "/ads/block"):
                return try await Self.json(Self.adBlock(
                    selectors: (body["selectors"] as? [String]) ?? [],
                    urlPattern: Self.string(body, "urlPattern"),
                    requests: (body["requests"] as? [String]) ?? [],
                    index: Self.index(body)
                ))
            case ("GET", "/filters"):
                return try Self.json(Self.filterLists())
            case ("POST", "/filters/probe"):
                if let regexes = body["regexes"] as? [String] {
                    return try await Self.json(Self.filterProbeRegexes(regexes))
                }
                return try await Self.json(Self.filterProbe(
                    abp: Self.string(body, "abp") ?? "",
                    includeHiding: (body["includeHiding"] as? Bool) ?? true
                ))
            case ("POST", "/filters/refresh"):
                return try Self.json(Self.filterListsRefresh(
                    id: Self.string(body, "id"),
                    force: (body["force"] as? Bool) ?? true
                ))
            case ("GET", "/media/exports"):
                return try Self.json(Self.mediaExports())
            case ("POST", "/media/exports/cancel"):
                return try Self.json(Self.mediaExportCancel(id: Self.string(body, "id") ?? ""))
            case ("POST", "/agent/directive"):
                // 会话级临时指令（可指定目标窗口，缺省 = 最新注册的活会话）：
                // 设置/清除（text 空串=清除）。E2E：设置 → 发消息 → 抓 system 断言。
                guard let session = Self.resolveSession(Self.string(body, "window")) else {
                    return try Self.json(["error": "no live agent session"])
                }
                session.setSessionDirective(Self.string(body, "text"))
                return try Self.json(["ok": true,
                                      "directive": session.activeDirective ?? ""])
            case ("POST", "/agent/note"):
                return try Self.json(Self.agentNote(
                    text: Self.string(body, "text") ?? "",
                    window: Self.string(body, "window")
                ))
            case ("GET", "/agent/guard"):
                guard let preference = AppState.live?.aiPreference else {
                    return try Self.json(["error": "preference unavailable"])
                }
                return try Self.json(["ok": true, "enabled": preference.guardReview])
            case ("POST", "/agent/guard"):
                guard let preference = AppState.live?.aiPreference else {
                    return try Self.json(["error": "preference unavailable"])
                }
                if let enabled = body["enabled"] as? Bool {
                    preference.guardReview = enabled
                }
                return try Self.json(["ok": true, "enabled": preference.guardReview])
            case ("POST", "/agent/guard/check"):
                // 离线跑一次 AI 动作复查（E2E/调试）：不经过 gate、不动回合。
                // 规则来源显式给（identity/rules/directive），模型走偏好档案。
                guard let preference = AppState.live?.aiPreference else {
                    return try Self.json(["error": "preference unavailable"])
                }
                guard let tool = Self.string(body, "tool"), !tool.isEmpty else {
                    return try Self.json(["error": "missing tool"])
                }
                let argsJSON: String
                if let raw = Self.string(body, "arguments"), !raw.isEmpty {
                    argsJSON = raw
                } else if let obj = body["arguments"], !(obj is NSNull),
                          let data = try? JSONSerialization.data(withJSONObject: obj) {
                    argsJSON = String(data: data, encoding: .utf8) ?? "{}"
                } else {
                    argsJSON = "{}"
                }
                let input = AgentGuard.Input(
                    toolName: tool,
                    argumentsJSON: argsJSON,
                    identity: Self.string(body, "identity") ?? "",
                    outputRules: (body["rules"] as? [String]) ?? [],
                    sessionDirective: Self.string(body, "directive"))
                // 与真实 gate 路径同源：走旁路档案（无则跟随对话模型），
                // E2E 才能只动 bypass-profile 不碰主配置。
                let prefs = preference.bypassPreferences() ?? preference
                let verdict = await GuardReviewer.review(preference: prefs, input: input)
                switch verdict {
                case .allow:
                    return try Self.json(["ok": true, "verdict": "allow"])
                case .flag(let reason):
                    return try Self.json(["ok": true, "verdict": "flag", "reason": reason])
                case .unsure:
                    return try Self.json(["ok": true, "verdict": "unsure"])
                }
            case ("GET", "/agent/doctor"):
                // 自诊断：逐项体检，桥与设置页同源。
                let report = await AgentDoctor.run()
                return try Self.json([
                    "ok": true,
                    "allOk": report.ok,
                    "passed": report.passed,
                    "total": report.checks.count,
                    "checks": report.checks.map { [
                        "name": $0.name, "ok": $0.ok, "detail": $0.detail,
                    ] },
                ])
            case ("GET", "/containers"):
                // 容器列表（E2E/远程可观测；含子代理临时容器）。
                return try Self.json([
                    "ok": true,
                    "containers": ContainerStore.shared.containers.map { [
                        "id": $0.id.uuidString, "name": $0.name,
                    ] },
                ])
            case ("GET", "/agent/modes"):
                // Agent 模式清单 + 各活窗口的绑定。
                let rosterModes = AgentScheduler.shared.liveSessions()
                var modeBindings: [String: String] = [:]
                for entry in rosterModes {
                    if let m = entry.store?.effectiveMode { modeBindings[entry.id.uuidString] = m.rawValue }
                }
                return try Self.json([
                    "ok": true,
                    "modes": AgentMode.allCases.map { [
                        "id": $0.rawValue, "name": $0.displayName,
                        "excluded": Array($0.excludedTools).sorted(),
                    ] },
                    "bindings": modeBindings,
                ])
            case ("GET", "/agent/roster"):
                // 多 Agent 名册：人设清单 + 各活窗口的绑定。
                let roster = AgentRosterStore.shared
                var bindings: [String: String] = [:]
                for entry in AgentScheduler.shared.liveSessions() {
                    guard let pid = roster.binding(for: entry.id) else { continue }
                    bindings[entry.id.uuidString] = pid.uuidString
                }
                return try Self.json([
                    "ok": true,
                    "personas": roster.personas.map { [
                        "id": $0.id.uuidString, "name": $0.name, "tone": $0.tone,
                    ] },
                    "bindings": bindings,
                ])
            case ("POST", "/agent/roster"):
                // action=add {name, tone} | remove {id} | bind {window, persona?}
                // （persona 省略 = 解绑，回落全局默认人设）。
                let roster = AgentRosterStore.shared
                switch Self.string(body, "action") ?? "" {
                case "add":
                    guard let persona = roster.add(
                        name: Self.string(body, "name") ?? "",
                        tone: Self.string(body, "tone") ?? "") else {
                        return try Self.json(["error": "missing name"])
                    }
                    return try Self.json(["ok": true, "id": persona.id.uuidString])
                case "remove":
                    guard let id = UUID(uuidString: Self.string(body, "id") ?? "") else {
                        return try Self.json(["error": "missing id"])
                    }
                    roster.remove(id: id)
                    return try Self.json(["ok": true])
                case "bind":
                    guard let session = Self.resolveSession(Self.string(body, "window")),
                          let registryID = session.registryID else {
                        return try Self.json(["error": "no live agent session"])
                    }
                    let personaID = Self.string(body, "persona").flatMap(UUID.init(uuidString:))
                    roster.bind(personaID: personaID, to: registryID)
                    return try Self.json([
                        "ok": true,
                        "window": registryID.uuidString,
                        "persona": personaID?.uuidString ?? "",
                    ])
                case "set-mode":
                    // 每窗口模式绑定：mode 省略 = 标准模式。
                    guard let session = Self.resolveSession(Self.string(body, "window")) else {
                        return try Self.json(["error": "no live agent session"])
                    }
                    let modeRaw = Self.string(body, "mode") ?? AgentMode.standard.rawValue
                    guard let mode = AgentMode(rawValue: modeRaw) else {
                        return try Self.json(["error": "unknown mode; valid: \(AgentMode.allCases.map(\.rawValue).joined(separator: "/"))"])
                    }
                    session.modeBinding = mode
                    return try Self.json(["ok": true, "mode": mode.rawValue])
                case "bind-model":
                    // 每窗口模型路由：profile 省略 = 跟随全局活动档案。
                    guard let session = Self.resolveSession(Self.string(body, "window")),
                          let registryID = session.registryID else {
                        return try Self.json(["error": "no live agent session"])
                    }
                    let pref = AppState.live?.aiPreference
                    if let raw = Self.string(body, "profile") {
                        guard let pid = UUID(uuidString: raw),
                              pref?.profiles.contains(where: { $0.id == pid }) == true else {
                            return try Self.json(["error": "unknown profile id"])
                        }
                        session.modelProfileID = pid
                        return try Self.json(["ok": true, "window": registryID.uuidString,
                                              "model": session.modelProfileName ?? ""])
                    }
                    session.modelProfileID = nil
                    return try Self.json(["ok": true, "window": registryID.uuidString, "model": ""])
                default:
                    return try Self.json(["error": "action must be add|remove|bind"])
                }
            case ("GET", "/agent/heartbeat"):
                let heartbeat = HeartbeatStore.shared
                var payload: [String: Any] = [
                    "ok": true,
                    "enabled": heartbeat.isEnabled,
                    "intervalMinutes": heartbeat.intervalMinutes,
                    "checklist": heartbeat.checklist,
                    "autoHandle": heartbeat.autoHandle,
                    "isBeating": heartbeat.isBeating,
                ]
                if let last = heartbeat.lastBeatAt { payload["lastBeatAt"] = last.timeIntervalSince1970 }
                if let result = heartbeat.lastResult { payload["lastResult"] = result }
                return try Self.json(payload)
            case ("POST", "/agent/heartbeat"):
                let heartbeat = HeartbeatStore.shared
                if let v = body["enabled"] as? Bool { heartbeat.isEnabled = v }
                if let v = body["intervalMinutes"] as? Int {
                    heartbeat.intervalMinutes = v
                }
                if let v = Self.string(body, "checklist") { heartbeat.checklist = v }
                if let v = body["autoHandle"] as? Bool { heartbeat.autoHandle = v }
                return try Self.json([
                    "ok": true,
                    "enabled": heartbeat.isEnabled,
                    "intervalMinutes": heartbeat.intervalMinutes,
                    "autoHandle": heartbeat.autoHandle,
                ])
            case ("POST", "/agent/heartbeat/fire"):
                // 立即跑一拍（E2E/调试）：绕过间隔与免打扰，决策与通知结果原样返回。
                let result = await HeartbeatStore.shared.beatNow()
                return try Self.json([
                    "ok": true,
                    "decision": result.decision,
                    "message": result.message,
                    "notified": result.notified,
                    "signals": result.signals,
                ])
            case ("GET", "/agent/hooks"):
                let hooks = AgentHooksStore.shared
                return try Self.json([
                    "ok": true,
                    "enabled": hooks.isEnabled,
                    "files": hooks.files.map { [
                        "name": $0.id,
                        "enabled": $0.isEnabled,
                        "error": $0.hasError ?? "",
                    ] },
                ])
            case ("POST", "/agent/hooks"):
                let hooks = AgentHooksStore.shared
                if let v = body["enabled"] as? Bool { hooks.isEnabled = v }
                return try Self.json(["ok": true, "enabled": hooks.isEnabled])
            case ("POST", "/agent/hooks/reload"):
                AgentHooksStore.shared.load()
                return try Self.json(["ok": true, "files": AgentHooksStore.shared.files.map(\.id)])
            case ("GET", "/agent/prompt"):
                return try Self.json(Self.pendingPrompt())
            case ("POST", "/agent/prompt/answer"):
                return try Self.json(Self.answerPendingPrompt(text: Self.string(body, "text") ?? ""))
            case ("POST", "/conversations/delete"):
                return try Self.json(Self.deleteConversations(body))
            case ("POST", "/agent/feedback"):
                return try Self.json(Self.setAgentFeedback(
                    messageId: Self.string(body, "messageId") ?? "",
                    vote: Self.string(body, "vote") ?? ""))
            case ("POST", "/agent/cancel"):
                return try Self.json(Self.agentCancel(window: Self.string(body, "window")))
            case ("POST", "/agent/send"):
                return try Self.json(Self.agentSend(
                    Self.string(body, "text"),
                    window: Self.string(body, "window"),
                    recordHistory: (body["recordHistory"] as? Bool) ?? false
                ))
            case ("GET", "/agent/crew"):
                let c = AgentCrewStore.shared.crew
                guard let c else { return try Self.json(["crew": NSNull()]) }
                let tasks: [[String: Any]] = c.tasks.map { t in
                    var row: [String: Any] = [
                        "index": t.index,
                        "state": t.state.rawValue,
                        "instruction": t.instruction,
                    ]
                    if let url = t.url { row["url"] = url }
                    if let tabID = t.tabID { row["tabId"] = tabID.uuidString }
                    if let r = t.result { row["result"] = String(r.prefix(2000)) }
                    return row
                }
                return try Self.json([
                    "crew": [
                        "objective": c.objective,
                        "settled": c.isSettled,
                        "done": c.completedCount,
                        "failed": c.failedCount,
                        "tasks": tasks,
                    ] as [String: Any],
                ])
            case ("POST", "/agent/crew-dispatch"):
                let objective = Self.string(body, "objective") ?? "research task"
                let raw = body["tasks"] as? [[String: Any]] ?? []
                let tasks = raw.map { t -> (url: String?, instruction: String) in
                    (t["url"] as? String, t["instruction"] as? String ?? "")
                }
                guard let app = AppState.live, let tm = try tabManager else {
                    return try Self.json(["error": "app/tab manager not ready"])
                }
                let surface = WindowToolSurface(app: app, tabManager: tm)
                let isolated = body["isolated"] as? Bool ?? false
                return try Self.json(["result": AgentCrewStore.shared.dispatch(
                    objective: objective, tasks: tasks, surface: surface, isolated: isolated)])
            case ("POST", "/agent/crew/cancel"):
                if let idx = body["index"] as? Int {
                    return try Self.json(["ok": true, "result": AgentCrewStore.shared.cancel(taskIndex: idx)])
                }
                AgentCrewStore.shared.cancelAll()
                return try Self.json(["ok": true])
            case ("GET", "/agent/tasks"):
                return try Self.json(Self.agentTasks())
            case ("POST", "/agent/tasks/create"):
                return try Self.json(Self.createAgentTask(
                    name: Self.string(body, "name") ?? "",
                    prompt: Self.string(body, "prompt") ?? "",
                    minutes: body["minutes"] as? Int,
                    hour: body["hour"] as? Int,
                    minute: body["minute"] as? Int,
                    window: Self.string(body, "window"),
                    builtin: Self.string(body, "builtin")
                ))
            case ("POST", "/agent/tasks/remove"):
                return try Self.json(Self.removeAgentTask(name: Self.string(body, "name") ?? ""))
            case ("POST", "/agent/tasks/fire"):
                return try Self.json(Self.fireAgentTask(name: Self.string(body, "name") ?? ""))
            case ("POST", "/memory/search"):
                return try Self.json(Self.searchMemory(query: Self.string(body, "query") ?? ""))
            case ("POST", "/memory/export"):
                return try Self.json(Self.exportMemory())
            case ("GET", "/memory/export"):
                // format=markdown：ReMe 式可读知识库（画像/分组事实/相关链接/摘要）。
                if query["format"] == "markdown" {
                    return try Self.json(["ok": true, "format": "markdown",
                                          "markdown": AgentMemoryStore.shared.markdownKB()])
                }
                return try Self.json(Self.exportMemory())
            case ("POST", "/memory/decay"):
                return try Self.json(Self.decayMemory(olderThanDays: body["days"] as? Int ?? 90))
            case ("GET", "/memory"):
                return try Self.json(Self.memorySnapshot())
            case ("GET", "/memory/conflicts"):
                return try Self.json(Self.memoryConflicts())
            case ("POST", "/memory/conflicts/resolve"):
                return try Self.json(Self.resolveMemoryConflict(body: body))
            case ("POST", "/memory/facts/add"):
                return try Self.json(Self.addMemoryFact(
                    content: Self.string(body, "content") ?? "",
                    category: Self.string(body, "category") ?? "fact",
                    scope: Self.string(body, "scope") ?? "global"
                ))
            case ("POST", "/memory/facts/update"):
                return try Self.json(Self.updateMemoryFact(
                    id: Self.string(body, "id") ?? "",
                    content: Self.string(body, "content") ?? ""
                ))
            case ("POST", "/memory/facts/delete"):
                return try Self.json(Self.deleteMemoryFact(id: Self.string(body, "id") ?? ""))
            case ("POST", "/memory/embed"):
                return try await Self.json(Self.embedProbe(text: Self.string(body, "text") ?? ""))
            case ("POST", "/memory/retrieval-eval"):
                return try await Self.json(Self.retrievalEval(body: body))
            case ("GET", "/skills"):
                return try Self.json(Self.listSkills())
            case ("POST", "/skills/distill"):
                return try await Self.json(Self.distillSkill(
                    window: Self.string(body, "window"),
                    save: body["save"] as? Bool ?? false))
            case ("POST", "/skills/reload"):
                return try Self.json(Self.reloadSkills())
            case ("POST", "/skills/delete"):
                return try Self.json(Self.deleteSkill(name: Self.string(body, "name") ?? ""))
            case ("POST", "/skills/import"):
                // path（本地 zip/目录/md）优先；否则 url（远程单 md）。
                if let path = Self.string(body, "path"), !path.isEmpty {
                    do {
                        let skill = try SkillStore.shared.importArchive(at: URL(fileURLWithPath: path))
                        return try Self.json(["ok": true, "name": skill.name,
                                              "multiFile": skill.directory != nil])
                    } catch {
                        return try Self.json(["error": error.localizedDescription])
                    }
                }
                return try await Self.json(Self.importSkill(
                    name: Self.string(body, "name") ?? "",
                    url: Self.string(body, "url") ?? ""
                ))
            case ("POST", "/agent/tasks/enable"):
                return try Self.json(Self.setAgentTaskEnabled(
                    name: Self.string(body, "name") ?? "",
                    enabled: body["enabled"] as? Bool
                ))
            case ("GET", "/agent/runs"):
                return try Self.json(Self.agentRuns(
                    name: Self.string(query, "name"),
                    count: Int(query["count"] ?? "20") ?? 20
                ))
            case ("GET", "/approvals/policy"):
                return try Self.json(Self.approvalPolicies())
            case ("POST", "/approvals/policy/add"):
                return try Self.json(Self.addApprovalPolicy(
                    toolName: Self.string(body, "tool") ?? "",
                    decision: Self.string(body, "decision") ?? ""
                ))
            case ("POST", "/approvals/policy/remove"):
                return try Self.json(Self.removeApprovalPolicy(
                    toolName: Self.string(body, "tool") ?? ""
                ))
            case ("GET", "/approvals/history"):
                return try Self.json(Self.approvalHistory(count: Int(query["count"] ?? "20") ?? 20))
            case ("POST", "/approvals/simulate"):
                return try Self.json(Self.simulateApproval())
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

    /// 通知策略的桥 JSON 形态（GET/POST /notifications/policy 共用）。
    private static func notificationPolicyJSON(_ policy: NotificationPolicy) -> [String: Any] {
        [
            "quietHoursEnabled": policy.quietHoursEnabled,
            "quietStart": NotificationPolicy.hhmm(fromMinutes: policy.quietStartMinute),
            "quietEnd": NotificationPolicy.hhmm(fromMinutes: policy.quietEndMinute),
            "dailyRoutineLimit": policy.dailyRoutineLimit,
        ]
    }

    // MARK: - Accessors

    private var tabManager: TabManager? {
        get throws { TabSessionCoordinator.shared.activeTabManager }
    }

    /// 桥直驱 agent 工具链的取件：deliveryTarget 会话的 provider 与活 webview。
    /// pageExtract 只读；pageAction 走同一实现（persist/outbound 的授权语义
    /// 仍由 agent 审批链承担——桥只放行 local 效果动作的调用方自查）。
    private static func dppToolProvider() -> BrowserToolProvider? {
        AgentScheduler.shared.deliveryTarget?.toolProvider
    }

    private static func dppWebViewForTools() -> WKWebView? {
        AgentScheduler.shared.deliveryTarget?.toolSurface?.tabManager?.selectedTab?.browser.webView
    }

    private static func toolArgsJSON(_ dict: [String: Any]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    func resolveIndex(_ index: Int?) -> Tab? {
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
                "suspended": tab.isSuspended,
                "loading": tab.isLoading,
                "domNodes": tab.browser.lastDomNodeCount,
                "scrollY": tab.browser.lastScrollY,
                "workflowSuggestion": tab.browser.pendingWorkflowSuggestion.map { suggestion -> Any in
                    ["name": suggestion.name, "host": suggestion.host]
                } ?? NSNull(),
            ]
        }
        return [
            "tabs": tabs,
            "selected": tm?.selectedIndex ?? -1,
            "agentBusy": AgentScheduler.shared.deliveryTarget?.isProcessing ?? false,
            "isActive": NSApp.isActive,
            "hasKeyWindow": NSApp.keyWindow != nil,
            // 启动行为与崩溃标志（v0.7.19）：重启类断言读它。
            "startupBehavior": Settings().startupBehavior.rawValue,
            "launchedAfterCrash": TabSessionCoordinator.shared.launchedAfterCrash,
            // 启动预算（v0.7.26）：首窗可交互 ms + 预算；回归断言读它。
            "startup": [
                "firstWindowMs": StartupMetric.firstWindowMs.map { $0 as Any } ?? NSNull(),
                "budgetMs": StartupMetric.budgetMs,
            ] as [String: Any],
            // Agent 的文件工具以这个目录为工作区——自动化/评估要把 fixture
            // 放进它才能免审批被 readFile 读到。
            "agentWorkspace": SystemCommandStore.shared.workingDirectoryText,
            // 阅读模式状态（v0.7.28）：提取后的 baseURL/内容长度是探针能断言
            // "阅读模式真的拿到了这一页"的最小证据。
            "reader": readerState(tm?.selectedTab),
        ]
    }

    private static func readerState(_ tab: Tab?) -> [String: Any] {
        guard let tab else { return ["active": false] }
        return [
            "active": tab.browser.isReadingMode,
            "loading": tab.browser.isReaderLoading,
            "baseURL": tab.browser.readerBaseURLString,
            "title": tab.browser.readerTitle,
            "contentChars": tab.browser.readerContent.count,
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
        // 本地媒体/PDF 走专用查看器（与地址栏 navigateToURL 同一规矩——
        // WKWebView 对 file:// 媒体不渲染，直接 load 落"插件处理的加载"错误页）。
        if url.isFileURL, SelectedTabContent.isOpenableFile(url) {
            let browser = tab.browser
            let ext = url.pathExtension.lowercased()
            await MainActor.run {
                if ext == "pdf" {
                    browser.pdfViewerFileName = url.lastPathComponent
                    browser.pdfViewerReturnURL = browser.webView.url
                    browser.pdfViewerURL = url
                } else if SelectedTabContent.mediaExtensions.contains(ext) {
                    browser.mediaViewerFileName = url.lastPathComponent
                    browser.mediaViewerURL = url
                } else {
                    tab.isOnNewTabPage = false
                    tab.urlString = finalURL
                    browser.webView.load(URLRequest(url: url))
                }
            }
            return ["ok": true, "navigatedTo": finalURL, "viewer": true]
        }
        tab.isOnNewTabPage = false
        tab.urlString = finalURL
        // 挂起标签先唤醒：挂起路径把 navigationDelegate 置了 nil（省资源的
        // 既有设计），直接 load 的话 didFinish/didCommit 全不来——桥拿不到
        // 任何加载完成信号（DPP 解析、isLoading 清零、pageReady 全断）。
        // unsuspend 走视图恢复链路把 delegate 重新挂上。
        if tab.isSuspended {
            (try? shared.tabManager)?.unsuspend(tab)
        }
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

    private static func newTab(url: String?, incognito: Bool, container: String?) async throws -> [String: Any] {
        let tm = try shared.tabManager
        guard let tm else { return ["error": "no tab manager"] }
        var containerID: UUID?
        var containerCreated = false
        if let container {
            // ContainerStore.shared is the UI's live instance — creating on
            // demand is write-safe; unknown names are created, not guessed.
            let store = ContainerStore.shared
            if let existing = store.containers.first(where: { $0.name == container }) {
                containerID = existing.id
            } else {
                containerID = store.addContainer(name: container).id
                containerCreated = true
            }
        }
        let before = tm.tabs.count
        tm.addTab(url: url, incognito: incognito, containerID: containerID)
        return ["ok": true, "index": before, "count": tm.tabs.count,
                "containerCreated": containerCreated]
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
            "zoom": tab.browser.pageZoom,
            "error": tab.browser.lastError?.localizedDescription ?? NSNull(),
            "mixedContent": tab.browser.mixedContentTotal,
            "mixedContentScripts": tab.browser.mixedContentScripts,
        ]
    }

    /// Full-page PDF of a tab → ~/desire_fullpage.pdf (no save panel; the
    /// MCP/drive path). createPDF captures the whole scrollable content.
    private static func fullPageScreenshot(index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index), !tab.isOnNewTabPage else {
            return ["error": "no such tab"]
        }
        let pdf: Data = await withCheckedContinuation { continuation in
            tab.browser.webView.createPDF(configuration: WKPDFConfiguration()) { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure: continuation.resume(returning: Data())
                }
            }
        }
        guard !pdf.isEmpty else { return ["error": "pdf capture failed"] }
        let path = NSHomeDirectory() + "/desire_fullpage.pdf"
        try pdf.write(to: URL(fileURLWithPath: path))
        return ["path": path, "bytes": pdf.count]
    }

    /// PNG snapshot of the selected tab's webview, written next to the
    /// project so external drivers can read it.
    /// Viewport snapshot of any tab (default selected). `inline` returns the
    /// PNG base64-encoded in the response (MCP resources read it directly);
    /// otherwise the PNG lands in ~/desire_automation.png.
    private static func screenshot(index: Int?, inline: Bool) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
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
        let dims = ["width": rep.pixelsWide, "height": rep.pixelsHigh]
        if inline {
            var result: [String: Any] = ["base64": png.base64EncodedString()]
            result.merge(dims) { _, new in new }
            return result
        }
        let path = NSHomeDirectory() + "/desire_automation.png"
        try png.write(to: URL(fileURLWithPath: path))
        var result: [String: Any] = ["path": path]
        result.merge(dims) { _, new in new }
        return result
    }

    /// Window/view geometry snapshot — the diagnostic for fullscreen and
    /// panel bugs, which are all about who owns which frame. Reports the web
    /// view's own frame plus every window's frame, style mask and screen, so
    /// a mismatch (e.g. a fullscreen window hosting a web view still sized to
    /// the browser window, or SwiftUI re-laying-out a web view WebKit
    /// reparented into its fullscreen window) is visible without screen
    /// capture.
    private static func geometry(index: Int?) throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        let webView = tab.browser.webView

        func rect(_ r: CGRect) -> [Double] {
            [Double(r.origin.x), Double(r.origin.y), Double(r.size.width), Double(r.size.height)]
        }

        var chain: [String] = []
        var view: NSView? = webView
        while let current = view {
            let frame = current.frame
            chain.append("\(type(of: current)) \(Int(frame.width))x\(Int(frame.height))@\(Int(frame.origin.x)),\(Int(frame.origin.y))")
            view = current.superview
        }

        // Subview tree (depth-limited) — shows WebKit's fullscreen
        // placeholder and its VisionKit image-analysis overlay when present.
        func tree(_ root: NSView, depth: Int) -> [String] {
            guard depth > 0 else { return [] }
            var out: [String] = []
            for sub in root.subviews {
                let f = sub.frame
                var line = "\(type(of: sub)) \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
                if sub.isHidden { line += " hidden" }
                out.append(line)
                out.append(contentsOf: tree(sub, depth: depth - 1).map { "  " + $0 })
            }
            return out
        }

        let windows: [[String: Any]] = NSApp.windows.map { window in
            var entry: [String: Any] = [
                "class": String(describing: type(of: window)),
                "frame": rect(window.frame),
                "contentLayout": rect(window.contentLayoutRect),
                "styleMask": Int(window.styleMask.rawValue),
                "isFullScreen": window.styleMask.contains(.fullScreen),
                "isKey": window.isKeyWindow,
                "visible": window.isVisible,
                "number": window.windowNumber,
            ]
            if let screen = window.screen {
                entry["screenFrame"] = rect(screen.frame)
                entry["screenVisibleFrame"] = rect(screen.visibleFrame)
            }
            if window === webView.window { entry["hostsWebView"] = true }
            return entry
        }

        return [
            "webViewFrame": rect(webView.frame),
            "webViewBounds": rect(webView.bounds),
            "webViewWindowNumber": webView.window?.windowNumber ?? -1,
            "webViewWindowClass": webView.window.map { String(describing: type(of: $0)) } ?? "nil",
            "webViewSuperviewClass": webView.superview.map { String(describing: type(of: $0)) } ?? "nil",
            "viewChain": chain,
            "webViewSubviews": tree(webView, depth: 3),
            "fullscreenState": String(describing: webView.fullscreenState),
            "windows": windows,
        ]
    }

    /// 调试面板的自动化入口：`/devtools/eval` 走控制台的 REPL 路径（执行 + 把
    /// 输入与结果写进日志），`/devtools/inspect` 用内置元素拾取器把某个选择器
    /// 的结果填进 Element 页签（无需真的点页面），`GET /devtools` 给出面板状态。
    private static func devToolsEval(js: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "empty js"]
        }
        await store.evaluateConsoleInput(js, in: tab.browser.webView, tabID: tab.id)
        return [
            "ok": true,
            "tab": tab.id.uuidString,
            "consoleCount": store.consoleMessages.count,
            "last": store.consoleMessages.suffix(2).map { ["\($0.level.rawValue)": $0.message] },
        ]
    }

    private static func devToolsInspect(selector: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["error": "empty selector"] }
        let webView = tab.browser.webView
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        tab.browser.elementPickIntent = .devTools
        tab.browser.isPickingElement = true
        webView.evaluateJavaScript(WebView.pickerJS, in: nil, in: .page, completionHandler: nil)
        try await Task.sleep(for: .milliseconds(250))
        let clickJS = """
        (function() {
            var el = document.querySelector('\(escaped)');
            if (!el) return 'not-found';
            el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            return 'clicked';
        })()
        """
        let result: String = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(clickJS) { value, _ in
                continuation.resume(returning: (value as? String) ?? "nil")
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        store.setActivePanel(.element)
        let element = store.inspectedElement
        return [
            "ok": result == "clicked",
            "result": result,
            "selector": element?.selector ?? "",
            "cssPath": element?.cssPath ?? "",
            "matchingRules": (element?.matchingRules ?? []).map { ["selector": $0.selector, "css": $0.css] },
            "crossOriginSheets": element?.crossOriginSheets ?? 0,
        ]
    }

    /// 改元素的内联样式 / 属性（值为空串 = 删除）。等价于 Element 页签里的编辑。
    private static func devToolsEdit(
        selector: String,
        style: [String: String],
        attributes: [String: String],
        index: Int?
    ) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        guard !selector.isEmpty else { return ["error": "empty selector"] }
        let webView = tab.browser.webView
        for (name, value) in style {
            await store.setElementStyle(selector: selector, name: name, value: value.isEmpty ? nil : value, in: webView)
        }
        for (name, value) in attributes {
            await store.setElementAttribute(selector: selector, name: name, value: value.isEmpty ? nil : value, in: webView)
        }
        return [
            "ok": true,
            "selector": store.inspectedElement?.selector ?? "",
            "attributes": store.inspectedElement?.attributes ?? [:],
            "inlineStyles": store.inspectedElement?.cssProperties.map(\.name) ?? [],
        ]
    }

    /// 当前标签页数据存储里的 Cookie 与 Web 存储（Application 页签的数据源）。
    private static func devToolsApplication(index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        let webView = tab.browser.webView
        let cookies = await store.loadCookies(in: webView.configuration.websiteDataStore)
        let local = await store.loadWebStorage(kind: .local, in: webView)
        let session = await store.loadWebStorage(kind: .session, in: webView)
        let extensions = store.extensionStorageSnapshots()
        let databases = await store.loadIndexedDB(in: webView)
        let caches = await store.loadCacheStorage(in: webView)
        let workers = await store.loadServiceWorkers(in: webView)
        return [
            "section": store.applicationSection.rawValue,
            "extensions": extensions.map { snapshot in
                [
                    "id": snapshot.id,
                    "name": snapshot.name,
                    "count": snapshot.items.count,
                    "sample": snapshot.items.keys.sorted().prefix(8).map { $0 },
                    "keys": snapshot.items.keys.sorted(),
                ] as [String: Any]
            },
            "cookies": [
                "count": cookies.count,
                "httpOnly": cookies.filter(\.isHttpOnly).count,
                "sample": cookies.prefix(8).map { "\($0.name)@\($0.domain)" },
            ],
            "localStorage": [
                "count": local.count,
                "sample": local.prefix(8).map(\.key),
            ],
            "sessionStorage": [
                "count": session.count,
                "sample": session.prefix(8).map(\.key),
            ],
            "indexedDB": [
                "count": databases.count,
                "sample": databases.prefix(8).map { "\($0.database)/\($0.name) (\($0.count))" },
            ],
            "cacheStorage": [
                "count": caches.count,
                "sample": caches.prefix(8).map { "\($0.cache): \($0.url)" },
            ],
            "serviceWorkers": [
                "count": workers.count,
                "sample": workers.prefix(8).map { "\($0.state) \($0.scriptURL)" },
            ],
        ]
    }

    /// 写一条存储项（`kind` = localStorage / sessionStorage / extension）；
    /// `ext` 为插件 UUID（插件存储走 `WebExtensionStore`，不是文件）。
    /// 空 value 允许（Chrome 里也有空值键），key 必须给。
    private static func devToolsSetStorage(kind: String, key: String, value: String, extID: String?, domain: String?, index: Int?) async throws -> [String: Any] {
        guard !key.isEmpty else { return ["error": "key required"] }
        switch kind {
        case "cookie":
            // 新增/改值：`domain` 必填（面板会带当前页面域），path 默认 "/"。
            guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
            guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
            guard let domain, !domain.isEmpty else { return ["error": "domain required for cookies"] }
            guard let cookie = store.makeCookie(
                name: key,
                value: value,
                domain: domain,
                path: "/",
                secure: false,
                httpOnly: false
            ) else { return ["error": "could not build cookie"] }
            await store.setCookie(cookie, in: tab.browser.webView.configuration.websiteDataStore)
        case "localStorage", "sessionStorage":
            guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
            guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
            await store.setStorageItem(
                kind: kind == "localStorage" ? .local : .session,
                key: key,
                value: value,
                in: tab.browser.webView
            )
        case "extension":
            guard let extID else { return ["error": "ext required"] }
            guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
            store.setExtensionStorageValue(pluginID: extID, key: key, value: value)
        default:
            return ["error": "unknown kind"]
        }
        return ["ok": true]
    }

    /// 删除一条存储项（`kind` = cookie / localStorage / sessionStorage /
    /// extension / indexedDB / cache / serviceWorker）。
    private static func devToolsDeleteStorage(kind: String, key: String?, extID: String?, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        let webView = tab.browser.webView
        switch kind {
        case "cookie":
            guard let key else { return ["error": "key required"] }
            let dataStore = webView.configuration.websiteDataStore
            let cookies = await store.loadCookies(in: dataStore)
            guard let cookie = cookies.first(where: { "\($0.name)@\($0.domain)" == key }) else {
                return ["error": "no such cookie"]
            }
            await store.deleteCookie(name: cookie.name, domain: cookie.domain, path: cookie.path, in: dataStore)
        case "localStorage", "sessionStorage":
            await store.removeStorageItem(kind: kind == "localStorage" ? .local : .session, key: key, in: webView)
        case "extension":
            guard let key else { return ["error": "key required"] }
            guard let extID else { return ["error": "ext required"] }
            store.setExtensionStorageValue(pluginID: extID, key: key, value: nil)
        case "indexedDB":
            guard let key, !key.isEmpty else { return ["error": "key = database name required"] }
            return ["ok": true, "detail": await store.deleteDatabase(named: key, in: webView) ?? ""]
        case "cache":
            // key = "cacheName<TAB>url"（面板的行 id 就是这个形状）。
            guard let key, let separator = key.range(of: "\u{1}") else {
                return ["error": "key = \"cacheName\\turl\" required"]
            }
            let cacheName = String(key[key.startIndex..<separator.lowerBound])
            let url = String(key[separator.upperBound...])
            await store.deleteCacheEntry(cache: cacheName, url: url, in: webView)
        case "cacheAll":
            return ["ok": true, "detail": await store.clearCaches(in: webView) ?? ""]
        case "serviceWorker":
            let detail: String?
            if let key, !key.isEmpty {
                detail = await store.unregisterServiceWorker(scope: key, in: webView)
            } else {
                detail = await store.unregisterAllServiceWorkers(in: webView)
            }
            // 注销后**注册表**可能仍列出该 worker，直到它的客户端（页面）卸载——
            // 返回页面侧的结果（`{"unregistered":N}`）让调用方能区分"没注销成"
            // 与"注销了但列表还没刷新"。
            return ["ok": true, "detail": detail ?? ""]
        default:
            return ["error": "unknown kind"]
        }
        return ["ok": true]
    }

    /// 展开一个控制台对象句柄（一层）：面板里点 chip 走的是同一条路径。
    /// 句柄由页面侧分配（`console-intercept.js` 的 `parts[].ref`），面板的
    /// 消息行文本里就能看到预览。
    private static func devToolsConsoleRef(ref: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        guard !ref.isEmpty else { return ["error": "ref required"] }
        guard let node = await store.loadConsoleRef(ref, in: tab.browser.webView) else {
            return ["error": "handle expired or page not loaded"]
        }
        return [
            "ctor": node.ctor ?? "",
            "preview": node.preview ?? "",
            "error": node.error ?? "",
            "props": (node.props ?? []).map { ["name": $0.name, "preview": $0.preview, "ref": $0.ref ?? ""] },
        ]
    }

    /// Element 页签的 DOM 树（一层）：面板懒展开用的就是这条路径。
    /// `path` 是 nth-child 链（省略 = `<html>`）。
    private static func devToolsTree(path: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        guard let node = await store.loadTreeChildren(path: path, in: tab.browser.webView) else {
            return ["error": "could not read the tree (no page, stale path, or script missing)"]
        }
        var children: [[String: Any]] = []
        for child in node.children ?? [] {
            children.append([
                "path": child.path,
                "tag": child.tag,
                "id": child.elementID ?? "",
                "classes": child.classes,
                "childCount": child.childCount,
                "text": child.text ?? "",
                "selector": child.selector,
            ])
        }
        return [
            "path": node.path,
            "tag": node.tag,
            "childCount": node.childCount,
            "truncated": node.truncated ?? false,
            "selector": node.selector,
            "children": children,
        ]
    }

    /// 重放一条已记录的请求（面板详情里的 ↻ 按钮走同一条路径）：在页面里用
    /// 同样的方法/头/体再发一次，结果与异常都写进控制台。
    private static func devToolsReplay(url: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        guard !url.isEmpty else { return ["error": "empty url"] }
        // 先在本标签页的记录里找，找不到就用 URL 现造一条（只重发 GET 语义）。
        let request = store.networkRequests.last { $0.url == url && $0.tabID == tab.id }
            ?? NetworkRequest(url: url, method: "GET", resourceType: .other, tabID: tab.id)
        await store.replayRequest(request, in: tab.browser.webView)
        return [
            "ok": true,
            "method": request.method,
            "url": request.url,
            "console": store.scopedConsoleMessages.suffix(3).map { "\($0.level.rawValue): \($0.message)" },
        ]
    }

    /// 取一个页面资源并落盘（面板里是内联预览，这里是它的可脚本化版本）：
    /// 走页面自己的 fetch（带 cookie），因此同源资源一定能拿到；跨域看 CORS。
    private static func devToolsPreview(url: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        guard !url.isEmpty else { return ["error": "empty url"] }
        let request = NetworkRequest(url: url, method: "GET", resourceType: .image, tabID: tab.id)
        let dataURL: String?
        do {
            dataURL = try await store.previewImageDataURL(for: request, in: tab.browser.webView)
        } catch {
            let userInfo = (error as NSError).userInfo
            let detail = (userInfo["WKJavaScriptExceptionMessage"] as? String)
                ?? (userInfo["NSLocalizedDescriptionKey"] as? String)
                ?? "\(error)"
            return ["error": detail]
        }
        guard let dataURL else {
            return ["error": "could not load (cross-origin, not an image, or over the size cap)"]
        }
        guard let comma = dataURL.firstIndex(of: ",") else { return ["error": "malformed data url"] }
        let meta = String(dataURL[dataURL.startIndex..<comma])
        let mime = meta.replacingOccurrences(of: "data:", with: "").replacingOccurrences(of: ";base64", with: "")
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]), options: .ignoreUnknownCharacters) else {
            return ["error": "bad base64 payload"]
        }
        let path = NSHomeDirectory() + "/desire_devtools_preview.png"
        try? data.write(to: URL(fileURLWithPath: path))
        return ["ok": true, "path": path, "bytes": data.count, "mime": mime]
    }

    /// 长连接摘要（拆成独立函数：整个字面量塞进 `devToolsState` 的字典里会让
    /// 类型检查超时——实测 "unable to type-check this expression in reasonable time"）。
    private static func streamSummaries(_ requests: [NetworkRequest]) -> [[String: Any]] {
        requests
            .filter { $0.streaming || !$0.frames.isEmpty }
            .suffix(5)
            .map { request -> [String: Any] in
                let inbound = request.frames.filter { $0.direction == .inbound }.count
                let outbound = request.frames.filter { $0.direction == .outbound }.count
                let last = request.frames.last.map { "\($0.direction.rawValue): \($0.payload)" } ?? ""
                return [
                    "url": request.url,
                    "status": request.statusCode ?? 0,
                    "frames": request.frames.count,
                    "inbound": inbound,
                    "outbound": outbound,
                    "lastFrame": last,
                    "initiator": request.initiator ?? "",
                ]
            }
    }

    private static func devToolsState() -> [String: Any] {
        guard let store = AppState.live?.devToolsStore else { return ["error": "app state not ready"] }
        // 计数与列表都按**当前作用域**给（面板看到的就是这里的数），另外附
        // 全量计数 `totals`，便于断言"过滤真的生效了"。
        return [
            "panel": store.activePanel.rawValue,
            "devMode": store.isDevModeEnabled,
            "clearConsoleOnNavigate": store.clearConsoleOnNavigate,
            "tabScope": store.tabScope.bridgeValue,
            "activeTab": store.activeTabID?.uuidString ?? "",
            "tabs": store.knownTabs.map {
                ["id": $0.id.uuidString, "title": store.displayName(for: $0), "url": $0.url ?? ""]
            },
            "console": [
                "count": store.scopedConsoleMessages.count,
                "errors": store.consoleErrorCount,
                "warnings": store.consoleWarningCount,
                // 带上来源（`url:line`）——控制台来源列的正确性靠它断言。
                "last": store.scopedConsoleMessages.suffix(5).map { message -> String in
                    let source = message.url.map { "\($0):\(message.line ?? 0)" } ?? "-"
                    return "\(message.level.rawValue): \(message.message) @ \(source)"
                },
                // 最近几条消息里的对象句柄（面板点 chip 用的就是它们，
                // 配合 GET /devtools/console/ref 展开）。
                "objects": store.scopedConsoleMessages.suffix(5).flatMap { message in
                    (message.parts ?? []).filter(\.isObject).map { part -> [String: Any] in
                        ["ref": part.ref ?? "", "preview": part.preview ?? ""]
                    }
                },
            ],
            "network": [
                "count": store.scopedNetworkRequests.count,
                "failed": store.networkFailedCount,
                "pending": store.networkPendingCount,
                "bytes": store.networkTotalBytes,
                "cached": store.scopedNetworkRequests.filter { $0.fromCache == true }.count,
                "last": store.scopedNetworkRequests.suffix(5).map {
                    var line = "\($0.method) \($0.statusCode ?? 0)\($0.fromCache == true ? " [cache]" : "") \($0.url)"
                    if let initiator = $0.initiator { line += " ← \(initiator)" }
                    return line
                },
                // 长连接（WebSocket / SSE）：帧数、最后一帧、发起者——面板详情
                // 展示的就是这些，桥要能断言。
                "streams": streamSummaries(store.scopedNetworkRequests),
            ],
            "totals": [
                "console": store.consoleMessages.count,
                "network": store.networkRequests.count,
            ],
            "element": ["selector": store.inspectedElement?.selector ?? ""],
        ]
    }

    /// 视频广告规则的解析状态：目录、远程源、每站来源（builtin/local/remote）、
    /// 最近错误。配合 `POST /rules/refresh`（本地重读 + 远程拉取）让整套"规则
    /// 热插拔"链路可被脚本化验证。
    private static func videoAdRules() -> [String: Any] {
        let store = VideoAdRulesStore.shared
        var perSite: [String: String] = [:]
        for site in VideoSite.allCases {
            perSite[site.key] = store.source(for: site).rawValue
        }
        return [
            "directory": VideoAdRulesStore.rulesDirectory.path,
            "remoteURL": store.remoteURL?.absoluteString ?? "",
            "remoteVersion": store.appliedRemoteVersion ?? "",
            "remoteFetchedAt": store.remoteFetchedAt.map {
                ISO.string(from: $0)
            } ?? "",
            "remoteScriptsTrusted": store.remoteScriptsTrusted,
            "isRefreshing": store.isRefreshing,
            "lastError": store.lastError ?? "",
            "status": store.statusLine(),
            "sites": perSite,
        ]
    }

    private static func history(count: Int) throws -> [String: Any] {
        // Fresh instance = read-only view of the persisted state; no shared
        // mutable state with the UI's own store instance. Entries are stored
        // newest-first (addEntry inserts at 0) — prefix is the most recent.
        let historyStore = HistoryStore()
        historyStore.applyScope(profileID: ProfileStore.shared.activeProfileID)
        let entries = historyStore.entries.prefix(count).map {
            ["id": $0.id.uuidString, "title": $0.title, "url": $0.url]
        }
        return ["entries": Array(entries)]
    }

    /// 死链清理（向导"Remove Selected"的桥等价）：逐条 find → remove（走
    /// 既有删除路径：墓碑 + 落盘 + 同步），返回删掉的与没找到的。
    private static func bookmarkHealthCleanup(urls: [String]) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard !urls.isEmpty else { return ["error": "missing urls"] }
        var removed: [String] = []
        var missing: [String] = []
        for url in urls {
            if let bookmark = app.bookmarkStore.find(url: url) {
                app.bookmarkStore.remove(bookmark)
                removed.append(url)
            } else {
                missing.append(url)
            }
        }
        return ["ok": true, "removed": removed, "missing": missing]
    }

    /// 历史按域名聚合（面板"站点分组"的桥等价；同一纯逻辑 HistoryGrouping）。
    private static func historyGrouped() throws -> [String: Any] {
        let historyStore = HistoryStore()
        historyStore.applyScope(profileID: ProfileStore.shared.activeProfileID)
        let groups = HistoryGrouping.byDomain(historyStore.entries).map { group -> [String: Any] in
            ["domain": group.domain,
             "count": group.entries.count,
             "latest": group.entries.first?.timestamp.timeIntervalSince1970 ?? 0]
        }
        return ["groups": groups,
                "total": historyStore.entries.count,
                "groupedTotal": groups.reduce(0) { $0 + ($1["count"] as? Int ?? 0) }]
    }

    // MARK: - History content index (v0.8.0)

    private static func historyContentSearch(query: String, limit: Int) throws -> [String: Any] {
        let hits = HistoryContentStore.shared.search(query: query,
                                                     limit: max(1, min(limit, 50)))
        return ["query": query,
                "hits": hits.map { hit -> [String: Any] in
                    ["url": hit.record.url,
                     "title": hit.record.title,
                     "snippet": hit.snippet,
                     "score": hit.score,
                     "updatedAt": hit.record.updatedAt.timeIntervalSince1970]
                }]
    }

    private static func historyContentStats() throws -> [String: Any] {
        ["enabled": HistoryContentStore.shared.isEnabled,
         "count": HistoryContentStore.shared.count]
    }

    private static func historyContentSetEnabled(_ enabled: Bool) throws -> [String: Any] {
        HistoryContentStore.shared.setEnabled(enabled)
        return try historyContentStats()
    }

    private static func historyContentClear() throws -> [String: Any] {
        HistoryContentStore.shared.clear()
        return try historyContentStats()
    }

    private static func whatsNewState() throws -> [String: Any] {
        let store = WhatsNewStore.shared
        return ["version": store.versionName,
                "buildKey": store.currentKey,
                "hasUnseen": store.hasUnseen,
                "presented": store.isPresented]
    }

    private static func bookmarks(tree: Bool = false) throws -> [String: Any] {
        // 读 **live 窗口 store**（与 add/remove 同源）——0.3.5 的"新实例按活跃
        // 人物开桶"在现代多档案架构下读到的是活跃档案的空桶，桥返回的书签
        // 永远是空的（0.7.1 走查实测：live 7 条 / GET 0 条）。
        guard let store = AppState.live?.bookmarkStore else {
            return ["entries": []]
        }
        if tree {
            func node(_ bookmark: Bookmark) -> [String: Any] {
                var dict: [String: Any] = [
                    "id": bookmark.id.uuidString,
                    "title": bookmark.title,
                ]
                if let url = bookmark.url {
                    dict["url"] = url
                } else {
                    dict["children"] = bookmark.children.map(node)
                }
                return dict
            }
            return ["tree": store.bookmarks.map(node)]
        }
        let entries = store.leafEntries.map { ["title": $0.title, "url": $0.url] }
        return ["entries": Array(entries)]
    }

    /// Drives any parameterless `BrowserCommand` (the same values the menu
    /// items post), so bookmarking, zooming, tab cycling, panel toggles and
    /// friends are testable without UI interaction. NOTE: delivery follows
    /// the key-window rule — the app must be active, or commands are dropped
    /// by design (multi-window correctness).
    private static func sendCommand(name: String, index: Int?) throws -> [String: Any] {
        let command: BrowserCommand
        switch name {
        case "newWindow": command = .newWindow
        case "newTab": command = .newTab
        case "newIncognitoTab": command = .newIncognitoTab
        case "closeTab": command = .closeTab
        case "reopenClosedTab": command = .reopenClosedTab
        case "selectTab":
            guard let index else { return ["error": "selectTab requires index"] }
            command = .selectTab(index)
        case "previousTab": command = .previousTab
        case "nextTab": command = .nextTab
        case "showHistory": command = .showHistory
        case "showBookmarks": command = .showBookmarks
        case "showDownloads": command = .showDownloads
        case "showSettings": command = .showSettings
        case "showPlugins": command = .showPlugins
        case "showElementBlock": command = .showElementBlock
        case "bookmarkPage": command = .bookmarkPage
        case "toggleFullScreen": command = .toggleFullScreen
        case "toggleFind": command = .toggleFind
        case "tabSearch": command = .tabSearch
        case "toggleSidebar": command = .toggleSidebar
        case "toggleResponsiveMode": command = .toggleResponsiveMode
        case "toggleReader": command = .toggleReader
        case "reload": command = .reload
        case "forceReload": command = .forceReload
        case "inspectElement": command = .inspectElement
        case "printPage": command = .printPage
        case "savePage": command = .savePage
        case "zoomIn": command = .zoomIn
        case "zoomOut": command = .zoomOut
        case "actualSize": command = .actualSize
        case "screenshot": command = .screenshot
        case "restoreArchivedSession": command = .restoreArchivedSession
        case "viewSource": command = .viewSource
        case "stopLoading": command = .stopLoading
        case "toggleTabOverview": command = .toggleTabOverview
        case "toggleAgentPanel": command = .toggleAgentPanel
        case "toggleWhiteboard": command = .toggleWhiteboard
        case "addSelectionToWhiteboard": command = .addSelectionToWhiteboard
        case "toggleAgentBall": command = .toggleAgentBall
        case "showAdBlockStats": command = .showAdBlockStats
        case "toggleSplitView": command = .toggleSplitView
        case "toggleDevTools": command = .toggleDevTools
        case "addToReadingList": command = .addToReadingList
        case "askAgentAboutPage": command = .askAgentAboutPage
        case "clearHistory": command = .clearHistory
        default:
            return ["error": "unknown command \(name)"]
        }
        CommandBus.shared.send(command)
        return ["ok": true, "command": name]
    }

    private static func downloads() throws -> [String: Any] {
        guard let store = DownloadStore.live else { return ["error": "store not ready"] }
        let items = store.downloads.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "file": item.filename,
                "state": item.state.rawValue,
                "paused": item.isPaused,
                // 并发上限排队中（v0.7.19）。
                "queued": item.isQueued,
                "path": item.fileURL?.path ?? "",
                "source": item.sourceURL?.absoluteString ?? "",
                "bytes": item.downloadedBytes,
                "total": item.totalBytes,
                "private": item.isPrivate,
                // 后台扫描缓存（scanFilePresence）——面板徽章同源，E2E/诊断用。
                "fileMissing": store.missingFiles.contains(item.id),
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

    private static func scheduledDownloads() throws -> [String: Any] {
        ["items": DownloadScheduler.shared.items.map(scheduledDict)]
    }

    private static func scheduleDownload(body: [String: Any]) throws -> [String: Any] {
        guard let raw = Self.string(body, "url"),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ["error": "invalid url"]
        }
        let now = Date()
        let startAt: Date
        if let seconds = (body["startAt"] as? NSNumber)?.doubleValue {
            startAt = Date(timeIntervalSince1970: seconds)
        } else if let inSeconds = (body["inSeconds"] as? NSNumber)?.doubleValue {
            startAt = now.addingTimeInterval(inSeconds)
        } else {
            startAt = now.addingTimeInterval(60)
        }
        guard let item = DownloadScheduler.shared.schedule(
            url: url,
            filename: Self.string(body, "filename"),
            startAt: startAt) else {
            return ["error": "could not schedule"]
        }
        return ["ok": true, "item": scheduledDict(item)]
    }

    private static func cancelScheduledDownload(id: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id),
              DownloadScheduler.shared.items.contains(where: { $0.id == uuid }) else {
            return ["error": "no such scheduled download"]
        }
        DownloadScheduler.shared.cancel(id: uuid)
        return ["ok": true]
    }

    private static func scheduledDict(_ item: ScheduledDownload) -> [String: Any] {
        ["id": item.id.uuidString,
         "url": item.url,
         "filename": item.filename,
         "startAt": item.startAt.timeIntervalSince1970]
    }

    /// Runs JS in the page and returns the result. Synthetic-event driven
    /// tests (middle click, keyboard) go through here.
    private static func execute(_ js: String, index: Int?,
                                world: String = "main") async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        // world=extension → 在插件隔离世界执行（调试插件 content script 必需——
        // 主世界探针看不到 extensionWorld 的 __desireExt 状态）。
        let result: Any? = await withCheckedContinuation { continuation in
            if world.hasPrefix("plugin:") {
                // 指定插件 world（plugin:<uuid>）——调试插件 content script。
                let uuidPart = world.dropFirst("plugin:".count)
                guard let uuid = UUID(uuidString: String(uuidPart)) else {
                    continuation.resume(returning: ["error": "bad plugin world id"])
                    return
                }
                tab.browser.webView.evaluateJavaScript(
                    js, in: nil, in: WebView.pluginWorld(uuid),
                    completionHandler: { result in
                        switch result {
                        case .success(let value): continuation.resume(returning: value)
                        case .failure: continuation.resume(returning: NSNull())
                        }
                    })
            } else if world == "extension" {
                tab.browser.webView.evaluateJavaScript(
                    js, in: nil, in: WebView.extensionWorld,
                    completionHandler: { result in
                        switch result {
                        case .success(let value): continuation.resume(returning: value)
                        case .failure: continuation.resume(returning: NSNull())
                        }
                    })
            } else {
                tab.browser.webView.evaluateJavaScript(
                    js,
                    completionHandler: { value, _ in
                        continuation.resume(returning: value ?? NSNull())
                    })
            }
        }
        return ["result": result ?? NSNull()]
    }

    /// Opens/closes app-shell panels so external drivers can screenshot
    /// SwiftUI chrome that /screenshot (webview-only) cannot see.
    private static func panel(name: String, show: Bool?, tab: String? = nil) throws -> [String: Any] {
        // 调试面板：`{"name":"devtools","tab":"network"}` —— 切页签并让面板可见，
        // 便于对真实窗口截图（`Table` 在进程内快照里渲染不出行）。
        if name == "devtools" {
            guard let app = AppState.live else { return ["error": "app state not ready"] }
            if let tab,
               let panel = DevToolsStore.DevPanel.allCases.first(where: { $0.rawValue.lowercased() == tab.lowercased() }) {
                app.devToolsStore.setActivePanel(panel)
            }
            // 面板可见性由 ContentView 的本地状态持有（不是 AppState），走命令
            // 总线触发它的 toggle；dev mode 开关与面板显隐在 toggleDevTools() 里
            // 始终成对翻转，所以它可以直接当作"面板是否已打开"的判据。
            if !app.devToolsStore.isDevModeEnabled {
                CommandBus.shared.send(.toggleDevTools)
            }
            return [
                "ok": true,
                "visible": app.devToolsStore.isDevModeEnabled,
                "panel": app.devToolsStore.activePanel.rawValue,
            ]
        }
        guard name == "downloads" else { return ["error": "unknown panel"] }
        // v0.7.30：下载面板状态独立于 AppState（避免整个窗口重绘导致弹出卡顿）。
        let visible = show ?? !DownloadsPresentation.shared.isPresented
        DownloadsPresentation.shared.isPresented = visible
        return ["ok": true, "visible": visible]
    }

    /// Renders an open panel's content view to PNG **in-process** via
    /// `dataWithPDF` — unlike `screencapture -l` this works while the
    /// display is occluded, on another Space, or capture-shielded.
    private static func panelSnapshot(name: String, tab: String?, width: CGFloat?, height: CGFloat?) async throws -> [String: Any] {
        // 调试面板：`?name=devtools&tab=console|network|element` —— 用当场渲染的
        // NSHostingView 拍照。面板不在 popover 里（主窗分栏），走 ImageRenderer 路径，
        // 且需要临时切一下 live store 的 activePanel（渲染完立刻还原）。
        if name == "devtools" {
            return try await devToolsSnapshot(tab: tab)
        }
        if name == "whiteboard" {
            // 白板快照：走 BoardRenderService 离屏成图（隐藏双引擎 webview +
            // 全内容高 takeSnapshot）——离屏 NSHostingView 不驱动 webview，
            // 成图只能这么拿；失败回退块清单卡（非成图，仅块数据断言）。
            let session = AgentScheduler.shared.deliveryTarget
            let board = session.map { WhiteboardStore.shared.board(for: $0.conversationId?.uuidString) }
                ?? WhiteboardStore.shared.mostRecentBoard()
                ?? WhiteboardSpec()
            let snapshotWidth = max(360, width ?? 520)
            // 渲染失败要可见（v8 React 迁移期）：错误进日志而非静默降级卡。
            var renderResult: BoardRenderService.Result?
            if !board.blocks.isEmpty {
                do {
                    renderResult = try await BoardRenderService.shared.render(board, width: snapshotWidth)
                } catch {
                    Log.agent.error("board snapshot render failed: \(String(describing: error), privacy: .public)")
                }
            }
            if !board.blocks.isEmpty,
               let result = renderResult,
               let tiff = result.image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]),
               let base64 = png.base64EncodedString() as String? {
                return ["format": "png", "base64": base64,
                        "rendered": result.rendered, "errors": result.errors,
                        "blocks": board.blocks.count]
            }
            let size = NSSize(width: snapshotWidth, height: max(360, height ?? 560))
            let rootView = AnyView(WhiteboardSnapshotView(board: board))
            let host = NSHostingView(
                rootView: rootView
                    .appAccent(AppAccent.current)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .frame(width: size.width, height: size.height)
            )
            host.frame = NSRect(origin: .zero, size: size)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return ["error": "bitmap rep failed"]
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]),
                  let base64 = png.base64EncodedString() as String? else {
                return ["error": "png encode failed"]
            }
            return ["format": "png", "base64": base64,
                    "fallback": "block-card",
                    "blocks": board.blocks.count]
        }
        if name == "adblock" || name == "passwords" || name == "batch" {
            // 三个离屏可渲染面板：数据都在单例/共享 store 里，init 即载。
            guard let app = AppState.live else { return ["error": "app state not ready"] }
            let size = NSSize(width: max(320, width ?? 440), height: max(320, height ?? 520))
            let rootView: AnyView
            switch name {
            case "adblock": rootView = AnyView(AdBlockPanel())
            case "passwords": rootView = AnyView(PasswordPanel(passwordStore: app.passwordStore))
            default: rootView = AnyView(BatchMediaPanel(
                store: BatchMediaExportStore.shared,
                mediaStore: MediaExportStore.shared))
            }
            let host = NSHostingView(
                rootView: rootView
                    .appAccent(AppAccent.current)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .frame(width: size.width, height: size.height)
            )
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.effectiveAppearance
                ?? NSApp.effectiveAppearance
            host.layoutSubtreeIfNeeded()
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(70))
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return ["error": "bitmap alloc failed"]
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                return ["error": "encode failed"]
            }
            let path = NSHomeDirectory() + "/desire_\(name)_panel.png"
            try png.write(to: URL(fileURLWithPath: path))
            return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
        }
        if name == "workspaces" {
            return try await workspacesSnapshot(width: width ?? 520, height: height ?? 640)
        }
        if name == "inbox" {
            return try await agentInboxSnapshot(width: width ?? 420, height: height ?? 900)
        }
        if name == "agentstats" {
            // Agent 面板的"使用统计"页：同样当场渲染（面板在主窗分栏里）。尺寸可指定——
            // 这一页在**窄面板**下最容易挤坏，要能按 420/900 两种宽度各拍一张。
            return try await agentStatsSnapshot(width: width ?? 420, height: height ?? 900)
        }
        if name == "syncchecklist" {
            // 接入引导 checklist（v0.7.23）：数据全在 syncStore 里、init 即载，
            // 离屏直拍（sheet 壳子要窗口，快照走不到——渲染的是内容层）。
            guard let app = AppState.live else { return ["error": "app state not ready"] }
            let size = NSSize(width: max(360, width ?? 560), height: max(320, height ?? 620))
            let rootView = AnyView(SettingsContainer { SyncOnboardingChecklist(store: app.syncStore) })
            let host = NSHostingView(
                rootView: rootView
                    .appAccent(AppAccent.current)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .frame(width: size.width, height: size.height)
            )
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.effectiveAppearance
                ?? NSApp.effectiveAppearance
            host.layoutSubtreeIfNeeded()
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(70))
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return ["error": "bitmap alloc failed"]
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                return ["error": "encode failed"]
            }
            let path = NSHomeDirectory() + "/desire_syncchecklist_panel.png"
            try png.write(to: URL(fileURLWithPath: path))
            return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
        }
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

    /// Agent"使用统计"页的快照：面板在主窗分栏里（不是 popover），所以同样当场建
    /// NSHostingView 渲染。`w`/`h` 由调用方给——窄面板是最容易挤坏的情况。
    private static func agentStatsSnapshot(width: CGFloat, height: CGFloat) async throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let size = NSSize(width: max(240, width), height: max(320, height))
        let host = NSHostingView(
            rootView: AgentStatsView(conversationStore: app.conversationStore,
                                     preference: app.aiPreference,
                                     onBack: {})
                .appAccent(AppAccent.current)
                // 面板在 app 里贴在窗口背景上；宿主默认透明，不铺底色会拍成
                // 浅底 + 浅字（看着像外观错乱）。
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: size.width, height: size.height)
        )
        host.frame = NSRect(origin: .zero, size: size)
        // 新宿主默认浅色外观，和 app 里的深色不一致。
        host.appearance = NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.effectiveAppearance
        // 先让出一小段时间：这一页的**热力图要量宽度再回写状态重排一次**（见
        // AgentStatsView.heatmap），不等这一拍就会拍到"量之前"的那一版。
        // 用 `Task.sleep` 而不是 `RunLoop.current.run`：后者在 async 上下文里会**阻塞
        // 协作线程池**（Release 构建会报 "unavailable from asynchronous contexts"，
        // 且 Swift 6 语言模式下是错误）；await 让出主 actor 时 runloop 照常转，效果一样。
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return ["error": "bitmap alloc failed"]
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return ["error": "encode failed"]
        }
        let path = NSHomeDirectory() + "/desire_agentstats.png"
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
    }

    /// 工作区面板快照（含「已归档会话」区块）。tabManager 用一次性实例——
    /// 这一页在快照里是纯展示（按钮不点）。
    private static func workspacesSnapshot(width: CGFloat, height: CGFloat) async throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let size = NSSize(width: max(360, width), height: max(320, height))
        let host = NSHostingView(
            rootView: WorkspacePanel(
                tabManager: TabManager(),
                settings: app.settings,
                contentBlocker: app.contentBlocker,
                videoAdBlocker: app.videoAdBlocker,
                profileDataStore: nil,
                onClose: {})
                .appAccent(AppAccent.current)
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: size.width, height: size.height)
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.effectiveAppearance
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return ["error": "bitmap alloc failed"]
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return ["error": "encode failed"]
        }
        let path = NSHomeDirectory() + "/desire_workspaces.png"
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
    }

    /// 收件箱页快照（与 agentstats 同款：当场建宿主渲染）。
    private static func agentInboxSnapshot(width: CGFloat, height: CGFloat) async throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let size = NSSize(width: max(240, width), height: max(320, height))
        let host = NSHostingView(
            rootView: AgentInboxView(conversationStore: app.conversationStore)
                .appAccent(AppAccent.current)
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: size.width, height: size.height)
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.effectiveAppearance
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return ["error": "bitmap alloc failed"]
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return ["error": "encode failed"]
        }
        let path = NSHomeDirectory() + "/desire_inbox.png"
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh]
    }

    /// 渲染调试面板某个页签的快照。面板在主窗的分栏里（不是 popover），所以
    /// 当场建一个 NSHostingView 渲染 `DevToolsPanel`；store 的 activePanel 需要
    /// 临时切换，渲染后立刻还原。
    private static func devToolsSnapshot(tab: String?) async throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.devToolsStore
        let original = store.activePanel
        defer { store.setActivePanel(original) }
        if let tab,
           let panel = DevToolsStore.DevPanel.allCases.first(where: { $0.rawValue.lowercased() == tab.lowercased() }) {
            store.setActivePanel(panel)
        }
        let size = NSSize(width: 420, height: 520)
        let host = NSHostingView(
            // 带上 tab：REPL 输入行与"选择元素"按钮需要目标标签页，不传的话
            // 快照会少掉这两块（和 app 里看到的不一致）。
            rootView: DevToolsPanel(store: store, tab: shared.resolveIndex(nil))
                .appAccent(AppAccent.current)
                // 面板在 app 里贴在窗口背景上；宿主视图默认透明，不铺底色
                // 拍出来就是白底 + 浅色文字的组合（看起来像外观错乱）。
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: size.width, height: size.height)
        )
        host.frame = NSRect(origin: .zero, size: size)
        // 新宿主视图默认浅色外观，拍出来会和 app 里的深色不一致。
        host.appearance = NSApp.windows.first { $0.isVisible && $0.frame.width > 800 }?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        host.layoutSubtreeIfNeeded()
        // 面板里有些内容是 `.task` 异步加载的（localStorage/扩展存储要等一次页面
        // JS 往返），host 建完立刻拍只会拍到空态。给它几个渲染节拍：睡一会儿 →
        // 重新布局 → 让 SwiftUI 提交新一帧，然后才截图（上限 ~700ms，别拖慢桥）。
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(70))
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return ["error": "bitmap alloc failed"]
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return ["error": "encode failed"]
        }
        let path = NSHomeDirectory() + "/desire_devtools.png"
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh, "panel": store.activePanel.rawValue]
    }

    /// Starts a store-owned download from a raw URL (MCP/bridge driven).
    private static func startDownload(_ url: String) throws -> [String: Any] {
        guard let store = DownloadStore.live else { return ["error": "store not ready"] }
        guard !url.isEmpty, let sourceURL = URL(string: url), sourceURL.scheme != nil else {
            return ["error": "missing or invalid url"]
        }
        let filename = sourceURL.lastPathComponent.isEmpty ? "download" : sourceURL.lastPathComponent
        store.startURLSessionDownload(sourceURL: sourceURL, filename: filename)
        return ["ok": true, "file": filename]
    }

    private static func pendingApproval(window: String? = nil) throws -> [String: Any] {
        guard let session = resolveSession(window) else {
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

    /// Native find-in-page: returns whether the query matches and the
    /// total occurrence count (same count JS the FindBar uses).
    private static func find(query: String, index: Int?, caseSensitive: Bool) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index), !query.isEmpty else {
            return ["error": "no such tab or empty query"]
        }
        let config = WKFindConfiguration()
        config.wraps = false
        config.caseSensitive = caseSensitive
        let found: Bool = await withCheckedContinuation { continuation in
            tab.browser.webView.find(query, configuration: config) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        let count: Int = await withCheckedContinuation { continuation in
            tab.browser.webView.evaluateJavaScript(
                WebView.findCountJS(query: query, caseSensitive: caseSensitive)) { value, _ in
                continuation.resume(returning: (value as? Int) ?? 0)
            }
        }
        let snippet: String = await withCheckedContinuation { continuation in
            tab.browser.webView.evaluateJavaScript(
                WebView.findSnippetJS(query: query, caseSensitive: caseSensitive)) { value, _ in
                continuation.resume(returning: (value as? String) ?? "")
            }
        }
        return ["matchFound": found, "count": count, "snippet": snippet]
    }

    /// Reader-mode extraction state for the selected tab (populated after
    /// window._desireReader() runs in the page).
    private static func readerState(index: Int?) throws -> [String: Any] {        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        let state = tab.browser
        return [
            "isReadingMode": state.isReadingMode,
            "loading": state.isReaderLoading,
            "title": state.readerTitle,
            "contentChars": state.readerContent.count,
        ]
    }

    /// Console messages captured by console-intercept.js (all tabs funnel
    /// into the shared DevToolsStore).
    private static func console(count: Int) throws -> [String: Any] {
        let store = AppState.live?.system.devToolsStore
        let rows = (store?.consoleMessages ?? []).suffix(count).map { m -> [String: Any] in
            ["level": m.level.rawValue, "message": m.message]
        }
        return ["messages": Array(rows)]
    }

    // MARK: - Web Apps (App Mode)

    private static func webApps() throws -> [String: Any] {
        ["apps": WebAppStore.shared.apps.map(webAppDict)]
    }

    private static func addWebApp(body: [String: Any]) throws -> [String: Any] {
        guard let raw = Self.string(body, "url"),
              let url = URL(string: raw),
              let app = WebAppStore.shared.add(
                url: url,
                name: Self.string(body, "name"),
                shareSession: body["shareSession"] as? Bool ?? false) else {
            return ["error": "invalid url"]
        }
        return ["ok": true, "app": webAppDict(app)]
    }

    private static func openWebApp(id: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id),
              WebAppStore.shared.app(id: uuid) != nil else {
            return ["error": "no such web app"]
        }
        NotificationCenter.default.post(name: .openWebApp, object: nil,
                                        userInfo: ["id": uuid.uuidString])
        return ["ok": true]
    }

    private static func deleteWebApp(id: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id),
              let app = WebAppStore.shared.app(id: uuid) else {
            return ["error": "no such web app"]
        }
        NotificationCenter.default.post(name: .closeWebApp, object: nil,
                                        userInfo: ["id": uuid.uuidString])
        WebAppStore.shared.remove(app)
        return ["ok": true]
    }

    private static func webAppDict(_ app: WebApp) -> [String: Any] {
        ["id": app.id.uuidString,
         "name": app.name,
         "url": app.startURL,
         "host": app.host,
         "shareSession": app.shareSession]
    }

    /// Detected browser profiles for the import sheet / E2E.
    private static func importBrowsers() throws -> [String: Any] {
        let profiles = BrowserImportService.detectedProfiles().map { p -> [String: Any] in
            ["source": p.source.rawValue,
             "name": p.name,
             "path": p.profilePath,
             "bookmarks": p.bookmarksPath.map { $0 as Any } ?? NSNull(),
             "history": p.historyPath.map { $0 as Any } ?? NSNull()]
        }
        return ["profiles": profiles]
    }

    private static func importPreview(path: String) throws -> [String: Any] {
        guard !path.isEmpty,
              let profile = BrowserImportService.profile(atPath: path) else {
            return ["error": "unrecognized browser profile path"]
        }
        let preview = BrowserImportService.preview(profile)
        return ["source": profile.source.rawValue,
                "name": profile.name,
                "path": profile.profilePath,
                "bookmarks": preview.bookmarkCount,
                "history": preview.historyCount,
                "homePage": preview.settings.homePage.map { $0 as Any } ?? NSNull(),
                "startupURLs": preview.settings.startupURLs,
                "warnings": preview.warnings]
    }

    private static func importRun(body: [String: Any]) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let path = Self.string(body, "path") ?? ""
        guard !path.isEmpty,
              let profile = BrowserImportService.profile(atPath: path) else {
            return ["error": "unrecognized browser profile path"]
        }
        let preview = BrowserImportService.preview(profile)
        let report = BrowserImportService.perform(
            profile,
            preview: preview,
            includeBookmarks: body["bookmarks"] as? Bool ?? true,
            includeHistory: body["history"] as? Bool ?? true,
            includeSettings: body["settings"] as? Bool ?? true,
            settings: app.settings,
            bookmarkStore: app.bookmarkStore,
            historyStore: app.historyStore)
        return ["ok": true,
                "source": profile.source.rawValue,
                "name": profile.name,
                "path": profile.profilePath,
                "bookmarksImported": report.bookmarksImported,
                "bookmarksSkipped": report.bookmarksSkipped,
                "historyImported": report.historyImported,
                "historySkipped": report.historySkipped,
                "settingsApplied": report.settingsApplied,
                "warnings": report.warnings]
    }

    /// Saved-password metadata + pending save-prompt state (never the
    /// secrets themselves).
    private static func passwords() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let rows = app.passwordStore.entries.map { p -> [String: Any] in
            ["domain": p.domain, "username": p.username]
        }
        var result: [String: Any] = ["entries": rows]
        if let pending = app.passwordStore.pendingSave {
            result["pendingSave"] = [
                "domain": pending.domain,
                "username": pending.username,
                "kind": pending.isUpdate ? "update" : "save",
            ]
        }
        return result
    }

    /// User plugin (userscript) list — metadata only, not the code.
    private static func pluginList() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        return ["plugins": app.pluginStore.plugins.map { p -> [String: Any] in
            [
                "id": p.id.uuidString,
                "name": p.name,
                "enabled": p.isEnabled,
                "pinned": p.isPinned,
                "icon": p.toolbarIcon,
                "patterns": p.urlPatterns,
                "runAt": p.runAt.rawValue,
            ]
        }]
    }

    /// Creates a userscript plugin (E2E / Agent primitive). The code runs
    /// in the isolated extension world with the browser.* API available.
    private static func pluginAdd(name: String, js: String, patterns: [String], runAt: String, css: String, pinned: Bool, icon: String?, background: String?) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ["error": "missing name"]
        }
        // background-only 插件是合法形态（MV3 service worker）——js 可空。
        let trimmedBackground = background?.isEmpty == false ? background! : nil
        guard !(js.isEmpty && trimmedBackground == nil) else {
            return ["error": "missing js or background"]
        }
        let plugin = Plugin(
            name: name,
            urlPatterns: patterns.isEmpty ? ["*"] : patterns,
            runAt: RunAt(rawValue: runAt) ?? .documentEnd,
            jsCode: js,
            cssCode: css,
            pinned: pinned,
            icon: icon,
            backgroundCode: trimmedBackground
        )
        app.pluginStore.add(plugin)
        return ["ok": true, "id": plugin.id.uuidString]
    }

    private static func pluginRemove(id: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let uuid = UUID(uuidString: id) else { return ["error": "invalid id"] }
        guard let plugin = app.pluginStore.plugins.first(where: { $0.id == uuid }) else {
            return ["error": "no such plugin"]
        }
        app.pluginStore.remove(plugin)
        return ["ok": true]
    }

    /// Seeds one credential (test setup / Agent primitive). No secret in the
    /// response.
    private static func addPassword(domain: String, username: String, password: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard !domain.isEmpty, !username.isEmpty, !password.isEmpty else {
            return ["error": "missing domain/username/password"]
        }
        app.passwordStore.save(domain: domain, username: username, password: password)
        return ["ok": true]
    }

    /// Imports a Chrome-format CSV. Reports counts only — the store never
    /// echoes secrets back over the bridge.
    private static func importPasswordCSV(_ csv: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard !csv.isEmpty else { return ["error": "missing csv"] }
        let count = app.passwordStore.importCSV(csv)
        return ["ok": true, "imported": count]
    }

    /// Resolves the pending save-password prompt (the sheet's Save / Not Now).
    private static func resolvePasswordSave(_ save: Bool) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let pending = app.passwordStore.pendingSave else {
            return ["error": "no pending password save"]
        }
        pending.respond(save)
        return ["ok": true, "save": save]
    }

    /// Deletes saved credentials for a domain; optional username narrows it to
    /// one account (test cleanup and the password panel's per-row delete).
    private static func deletePasswords(domain: String, username: String? = nil) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        // 删除只需要 domain/username（元数据）；别为删除去读密码（会弹授权）。
        let victims = app.passwordStore.find(domain: domain, loadSecrets: false)
            .filter { username == nil || $0.username == username }
        for entry in victims {
            app.passwordStore.delete(entry)
        }
        return ["ok": true, "deleted": victims.count]
    }

    /// 会话内查找（面板 ⌘F 的桥等价；同一纯逻辑）。
    private static func agentMessageFind(query: String, window: String?) throws -> [String: Any] {
        guard let session = resolveSession(window) else {
            return ["error": "no live agent session"]
        }
        let ids = AgentMessageSearch.matches(messages: session.messages, query: query)
        return ["query": query, "count": ids.count,
                "ids": ids.map(\.uuidString)]
    }

    /// 命令面板混合检索（与 UI 同一套纯逻辑 + 同一处快照构建）。
    private static func palette(query: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        var rows = PaletteSnapshot.rows(
            tabManager: TabSessionCoordinator.shared.activeTabManager,
            bookmarkStore: app.bookmarkStore,
            historyStore: app.historyStore,
            conversationStore: app.conversationStore)
        rows.append(contentsOf: CommandPalette.orderedCommandRows())
        let sections = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PaletteSearch.initialSections(rows: rows)
            : PaletteSearch.search(query, rows: rows)
        return ["query": query,
                "sections": sections.map { section in
                    ["source": section.source.rawValue,
                     "total": section.total,
                     "rows": section.rows.map { row in
                         ["id": row.id, "title": row.title,
                          "subtitle": row.subtitle, "url": row.url ?? ""]
                     }]
                }]
    }

    /// 清除本站 UI 覆盖（站点控制中心"Clear Site Overrides"的桥等价，
    /// 与 BrowsingActions.clearSiteControls 同序：store 级清除 + 活动标签
    /// 就地还原暗色样式/缩放/字体注入）。
    private static func clearSiteSettings(host: String) throws -> [String: Any] {
        guard let app = AppState.live, !host.isEmpty else { return ["error": "missing host"] }
        let store = app.siteSettingsStore
        store.clearOverrides(for: host)
        if let tab = TabSessionCoordinator.shared.activeTabManager?.selectedTab,
           tab.browser.webView.url?.host == host {
            tab.browser.webView.evaluateJavaScript(
                "(function(){var el=document.getElementById('desire-dark-mode');if(el)el.remove();})();",
                completionHandler: nil)
            tab.applyPageZoom(1.0, rememberIn: store)
            SiteFontApplier.apply(to: tab.browser.webView, host: host, store: store)
        } else {
            store.setZoom(1.0, for: host)
        }
        let font = store.effectiveFont(for: host)
        return ["ok": true, "host": host,
                "zoom": store.zoom(for: host),
                "darkMode": store.darkModeEnabled(for: host),
                "minFontSize": font.minFontSize,
                "fontFamily": font.fontFamily]
    }

    /// 双语对照状态（活动标签的口径；E2E 轮询直到 running=false）。
    private static func bilingualState() throws -> [String: Any] {
        let service = BilingualReadingService.shared
        let tab = TabSessionCoordinator.shared.activeTabManager?.selectedTab
        return ["on": tab.map { service.isOn(tabID: $0.id) } ?? false,
                "running": service.isRunning,
                "done": service.doneCount,
                "total": service.totalCount,
                "error": service.lastError ?? NSNull()]
    }

    /// 双语对照开/关（活动标签或指定 index 的标签）。
    private static func setBilingual(on: Bool, index: Int?) throws -> [String: Any] {
        guard let manager = TabSessionCoordinator.shared.activeTabManager else {
            return ["error": "no active window"]
        }
        let tab: Tab?
        if let index, index >= 0, index < manager.tabs.count {
            tab = manager.tabs[index]
        } else {
            tab = manager.selectedTab
        }
        guard let tab else { return ["error": "no such tab"] }
        BilingualReadingService.shared.toggle(
            webView: tab.browser.webView,
            tabID: tab.id,
            preference: AppState.live?.aiPreference)
        return try Self.bilingualState()
    }

    // MARK: Site settings / QuickDial / Element blocker

    private static func siteSettings(host: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.siteSettingsStore
        guard !host.isEmpty else { return ["error": "missing host"] }
        let font = store.effectiveFont(for: host)
        let own = store.fontOverride(for: host)
        // 注意别写 `optional?.rawValue.map { … }`：可选链会让 `.map` 落到
        // **String 自己的 map**（逐字符 → [Any]），JSONSerialization 遇到
        // __SwiftValue 直接抛 NSInvalidArgumentException（主 actor 僵尸）。
        let siteAutoPlay: Any
        if let raw = store.autoPlayOverride(for: host)?.rawValue {
            siteAutoPlay = raw
        } else {
            siteAutoPlay = NSNull()
        }
        return ["host": host,
                "zoom": store.zoom(for: host),
                "darkMode": store.darkModeEnabled(for: host),
                "blockedSelectors": store.blockedSelectors(for: host),
                // 生效值（站点覆盖或全局默认解析后）+ 站点显式值（null = 跟随默认）。
                "minFontSize": font.minFontSize,
                "fontFamily": font.fontFamily,
                "siteMinFontSize": own.min.map { $0 as Any } ?? NSNull(),
                "siteFontFamily": own.family.map { $0 as Any } ?? NSNull(),
                // 自动播放：显式覆写（null = 跟随）+ 生效档位（含视频平台默认豁免）。
                "siteAutoPlay": siteAutoPlay,
                "autoPlay": store.effectiveAutoPlay(
                    for: host, global: app.settings.autoPlayPolicy).rawValue,
                "globalAutoPlay": app.settings.autoPlayPolicy.rawValue]
    }

    /// 站点自动播放覆写。mode：allow / block / follow（清除覆写）。
    /// 生效点在 webview 创建期，因此注释里明确"下一个标签生效"——桥测试别
    /// 拿当前页断言播放策略。
    private static func setSiteAutoPlay(body: [String: Any]) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let host = Self.string(body, "host") ?? ""
        guard !host.isEmpty else { return ["error": "missing host"] }
        let mode = (Self.string(body, "mode") ?? "follow").lowercased()
        let store = app.siteSettingsStore
        switch mode {
        case "allow": store.setAutoPlay(.allow, for: host)
        case "block": store.setAutoPlay(.block, for: host)
        case "follow", "": store.setAutoPlay(nil, for: host)
        default: return ["error": "mode must be allow|block|follow"]
        }
        let siteAutoPlay: Any
        if let raw = store.autoPlayOverride(for: host)?.rawValue {
            siteAutoPlay = raw
        } else {
            siteAutoPlay = NSNull()
        }
        return ["ok": true, "host": host,
                "siteAutoPlay": siteAutoPlay,
                "autoPlay": store.effectiveAutoPlay(
                    for: host, global: app.settings.autoPlayPolicy).rawValue]
    }

    private static func setSiteDarkMode(host: String, enabled: Bool) throws -> [String: Any] {
        guard let app = AppState.live, !host.isEmpty else { return ["error": "missing host"] }
        app.siteSettingsStore.setDarkMode(enabled, for: host)
        return ["ok": true, "darkMode": app.siteSettingsStore.darkModeEnabled(for: host)]
    }

    private static func setSiteZoom(host: String, zoom: Double) throws -> [String: Any] {
        guard let app = AppState.live, !host.isEmpty else { return ["error": "missing host"] }
        app.siteSettingsStore.setZoom(zoom, for: host)
        return ["ok": true, "zoom": app.siteSettingsStore.zoom(for: host)]
    }

    /// 站点字体（最小字号/字体族）。三态：键**缺失** = 不动；`null` = 跟随
    /// 默认；数值/字符串 = 显式值（0/空串 = 本站关闭）。改完对活动标签立即
    /// 重注入——桥驱动时页面当场变化，不用刷新。
    private static func setSiteFont(body: [String: Any]) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let host = Self.string(body, "host") ?? ""
        guard !host.isEmpty else { return ["error": "missing host"] }
        let store = app.siteSettingsStore
        if body.keys.contains("minFontSize") {
            if body["minFontSize"] is NSNull {
                store.setMinFontSize(nil, for: host)
            } else if let value = body["minFontSize"] as? Int {
                store.setMinFontSize(value, for: host)
            } else if let value = body["minFontSize"] as? Double {
                store.setMinFontSize(Int(value), for: host)
            }
        }
        if body.keys.contains("fontFamily") {
            if body["fontFamily"] is NSNull {
                store.setFontFamily(nil, for: host)
            } else if let value = Self.string(body, "fontFamily") {
                store.setFontFamily(value, for: host)
            }
        }
        if let tab = TabSessionCoordinator.shared.activeTabManager?.selectedTab,
           tab.browser.webView.url?.host == host {
            SiteFontApplier.apply(to: tab.browser.webView, host: host, store: store)
        }
        let font = store.effectiveFont(for: host)
        let own = store.fontOverride(for: host)
        return ["ok": true,
                "host": host,
                "minFontSize": font.minFontSize,
                "fontFamily": font.fontFamily,
                "siteMinFontSize": own.min.map { $0 as Any } ?? NSNull(),
                "siteFontFamily": own.family.map { $0 as Any } ?? NSNull()]
    }

    private static func quickDial() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        return ["dials": app.quickDialStore.dials.map { ["title": $0.title, "url": $0.url] }]
    }

    // MARK: - 云同步

    private static func syncStatus() -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.syncStore
        let auth: String
        switch store.authState {
        case .signedOut: auth = "signedOut"
        case .signedIn(let username): auth = username
        }
        let defaults = UserDefaults.standard
        let cursors: [String: String] = [
            "bookmarks": defaults.string(forKey: "sync.cursor.bookmarks") ?? "",
            "quickdials": defaults.string(forKey: "sync.cursor.quickdials") ?? "",
            "reading_list": defaults.string(forKey: "sync.cursor.reading_list") ?? "",
            "keyboard_shortcuts": defaults.string(forKey: "sync.cursor.keyboard_shortcuts") ?? "",
            "settings": defaults.string(forKey: "sync.cursor.settings") ?? "",
            "agent_memory": defaults.string(forKey: "sync.cursor.agent_memory") ?? "",
            "agent_prefs": defaults.string(forKey: "sync.cursor.agent_prefs") ?? "",
            "history": defaults.string(forKey: "sync.cursor.history") ?? "",
        ]
        return [
            "auth": auth,
            "syncing": store.isSyncing,
            "lastSyncAt": store.lastSyncAt.map { $0.timeIntervalSince1970 } ?? NSNull(),
            "lastError": store.lastError ?? "",
            "server": store.serverBaseURL,
            "syncKey": [
                "has": store.hasSyncKey,
                "fingerprint": store.syncKeyFingerprint ?? "",
                "needsMigration": store.needsSecretMigration,
            ],
            "enabled": Dictionary(
                uniqueKeysWithValues: SyncDomain.allCases.map { ($0.rawValue, app.syncStore.isEnabled($0)) }
            ),
            "cursors": cursors,
            "pendingDeletions": [
                "bookmarks": app.bookmarkStore.pendingDeletions.count,
                "quickdials": app.quickDialStore.pendingDeletions.count,
                "reading_list": app.readingListStore.pendingDeletions.count,
                "history": app.historyStore.pendingDeletions.count,
            ],
            // 变更驱动同步的观测面：每域脏标记 + 最近一次结果
            "domains": Dictionary(
                uniqueKeysWithValues: SyncDomain.allCases.map { domain in
                    let status: [String: Any]
                    switch store.domainStatus[domain] {
                    case .ok(let date): status = ["ok": date.timeIntervalSince1970]
                    case .failed(let message): status = ["error": message]
                    case nil: status = [:]
                    }
                    return (domain.rawValue, [
                        "enabled": store.isEnabled(domain),
                        "dirty": store.isDirty(domain),
                        "status": status,
                    ])
                }
            ),
        ]
    }

    private static func syncNowBridge() async -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        await app.syncStore.syncNow()
        return syncStatus()
    }

    private static func syncAuth(_ body: [String: Any], register: Bool) async -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        do {
            if register {
                // 验证码:不传即由 store 自动拉取并用 dev 回显码(dev 环境)生产注册走 UI
                try await app.syncStore.register(
                    username: Self.string(body, "username") ?? "",
                    password: Self.string(body, "password") ?? ""
                )
            } else {
                try await app.syncStore.login(
                    username: Self.string(body, "username") ?? "",
                    password: Self.string(body, "password") ?? ""
                )
            }
            return syncStatus()
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private static func syncLogout() -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        app.syncStore.logout()
        return syncStatus()
    }

    private static func syncSetServer(_ baseURL: String) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard !baseURL.isEmpty else { return ["error": "missing baseURL"] }
        app.syncStore.setServerBaseURL(baseURL)
        return ["ok": true, "baseURL": app.syncStore.serverBaseURL]
    }

    // MARK: - 远程控制（E2E/自动化辅助；status 含会话密钥，仅限本地桥）

    private static func remoteToggle(_ enabled: Bool) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        app.remoteControlStore.setEnabled(enabled)
        return ["ok": true, "enabled": enabled]
    }

    private static func remotePairStart() -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        app.remoteControlStore.startPairing()
        return ["ok": true]
    }

    private static func remoteStatus() -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.remoteControlStore
        var pairing: [String: Any] = [:]
        if let secrets = store.pairingSecrets {
            pairing = ["code": secrets.code, "sessionKey": secrets.sessionKeyB64]
        }
        return [
            "enabled": store.isEnabled,
            "connection": store.connectionForBridge,
            "pairing": pairing,
            "devices": store.pairedDevices.map {
                ["desktopDeviceId": $0.desktopDeviceId,
                 "desktopName": $0.desktopName,
                 "controllerName": $0.controllerName,
                 "online": $0.online]
            },
        ]
    }

    /// 写一个可同步设置项（catalog 白名单内）；下个同步周期自然上推。
    private static func syncSetSetting(_ body: [String: Any]) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let key = Self.string(body, "key") else { return ["error": "missing key"] }
        let value: SettingsSyncValue
        if let bool = body["bool"] as? Bool {
            value = .bool(bool)
        } else if let number = body["number"] as? Double {
            value = .number(number)
        } else if let string = body["string"] as? String {
            value = .string(string)
        } else {
            return ["error": "missing value (string|bool|number)"]
        }
        guard app.syncStore.applyExternalSetting(key: key, value: value) else {
            return ["error": "unknown key or invalid value"]
        }
        return ["ok": true, "key": key]
    }

    /// 开/关一个同步类目（即用户在设置 → Sync 里拨的开关）。
    private static func syncSetDomain(_ body: [String: Any]) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let raw = Self.string(body, "domain"), let domain = SyncDomain(rawValue: raw) else {
            return ["error": "missing or unknown domain"]
        }
        guard let enabled = body["enabled"] as? Bool else { return ["error": "missing enabled"] }
        app.syncStore.setEnabled(domain, enabled)
        return syncStatus()
    }

    private static func addQuickDial(title: String, url: String) throws -> [String: Any] {
        guard let app = AppState.live, !url.isEmpty else { return ["error": "missing url"] }
        app.quickDialStore.add(title: title.isEmpty ? url : title, url: url)
        return ["ok": true, "count": app.quickDialStore.dials.count]
    }

    private static func deleteQuickDial(url: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let dial = app.quickDialStore.dials.first(where: { $0.url == url }) else {
            return ["error": "no such dial"]
        }
        app.quickDialStore.delete(id: dial.id)
        return ["ok": true]
    }

    private static func elementRules() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        return ["rules": app.elementBlockStore.rules.map { r -> [String: Any] in
            ["selector": r.cssSelector, "urlPattern": r.urlPattern]
        }]
    }

    private static func addElementRule(selector: String, pattern: String) throws -> [String: Any] {
        guard let app = AppState.live, !selector.isEmpty, !pattern.isEmpty else {
            return ["error": "missing selector or pattern"]
        }
        app.elementBlockStore.add(cssSelector: selector, urlPattern: pattern)
        return ["ok": true, "count": app.elementBlockStore.rules.count]
    }

    private static func removeElementRule(pattern: String, selector: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let rule = app.elementBlockStore.rules.first(where: {
            $0.urlPattern == pattern && $0.cssSelector == selector
        }) else { return ["error": "no such rule"] }
        app.elementBlockStore.remove(id: rule.id)
        return ["ok": true]
    }

    /// Address-bar suggestions for a query (local rows: navigate/search +
    /// bookmark/history matches, deduped). Network suggestions are
    /// deliberately NOT awaited — they arrive async and hit the network.
    /// 历史对话检索（工具 `searchConversations` 与这个端点共用 ConversationStore 的实现）。
    @MainActor
    private static func searchConversations(query: String, limit: Int) -> [String: Any] {
        // 查询用**新实例读盘**（与 `/bookmarks` 同一约定），不碰 UI 持有的那份。
        // R2-7：复用内存 store（此前每请求 new 一个 = 主 actor 全量读盘解码）。
        let store = AppState.live?.conversationStore ?? ConversationStore()
        let hits = store.search(query, limit: min(20, max(1, limit)))
        return ["query": query, "count": hits.count, "hits": hits.map { hit in
            ["id": hit.id.uuidString, "title": hit.title,
             "updatedAt": ISO.string(from: hit.updatedAt),
             "messages": hit.messageCount, "matchedIn": hit.matchedIn, "snippet": hit.snippet]
        }]
    }

    /// 删除会话（E2E 收尾清掉测试遗留；历史列表的批量删除同一个实现）。
    /// **写操作必须走 UI 持有的那份 store**（[[AGENTS]] 端点扩展模式）：用新实例删只会
    /// 删掉盘上的文件，正在显示的列表还留着那一行，"删除"看起来没生效。
    @MainActor
    private static func deleteConversations(_ body: [String: Any]) -> [String: Any] {
        var raw: [String] = []
        if let single = body["id"] as? String { raw.append(single) }
        if let many = body["ids"] as? [String] { raw.append(contentsOf: many) }
        let ids = Set(raw.compactMap { UUID(uuidString: $0) })
        guard !ids.isEmpty else { return ["error": "pass id or ids (UUID strings)"] }

        // 活会话（面板开着）走它；否则用 AppState 里那份——**和 UI 显示的是同一个对象**，
        // 删完列表立刻少一行。都没有（无头启动）才退回读盘的新实例。
        let live = AgentScheduler.shared.deliveryTarget
        let store = live?.conversationStore ?? AppState.live?.conversationStore ?? ConversationStore()
        let known = Set(store.conversations.map { $0.id })
        let hit = ids.intersection(known)
        store.delete(hit)
        var result: [String: Any] = ["ok": true, "deleted": hit.map { $0.uuidString }.sorted(),
                                     "missing": ids.subtracting(known).map { $0.uuidString }.sorted(),
                                     "scope": live != nil ? "live" : (AppState.live != nil ? "app" : "saved")]
        // 删掉的是**正在面板里显示的**那个会话时，把面板重置回初始空态——
        // 此前只删存储侧，面板残留已删消息且下一回合落盘会把文件写回复活。
        if let live, let liveID = live.conversationId, hit.contains(liveID) {
            live.handleConversationsDeleted(hit)
            result["liveConversationDeleted"] = true
        }
        return result
    }

    /// Token 使用统计（面板的统计页与这里共用 `UsageStats` 派生，同一份会话数据）。
    /// `days=N` 时附带最近 N 天的逐日序列（画图/对账用）。
    @MainActor
    private static func usageStats(days: Int?) -> [String: Any] {
        // 查询用**读盘的新实例**（与 /conversations/search、/agent/trace 同一约定）。
        let store = AppState.live?.conversationStore ?? ConversationStore()
        let preference = AppState.live?.aiPreference
        let stats = UsageStats.derive(from: store.conversations,
                                      price: { preference?.usagePrice(for: $0) })
        var payload: [String: Any] = [
            "totalTokens": stats.totalTokens,
            "promptTokens": stats.promptTokens,
            "completionTokens": stats.completionTokens,
            "bypassTokens": stats.bypassTokens,
            "turns": stats.turns,
            "conversations": stats.conversations,
            "peakDayTokens": stats.peakDayTokens,
            "longestConversationSeconds": (stats.longestConversation * 10).rounded() / 10,
            "currentStreak": stats.currentStreak,
            "longestStreak": stats.longestStreak,
            "unpricedTokens": stats.unpricedTokens,
            "models": stats.models.map { model -> [String: Any] in
                ["model": model.id,
                 "tokens": model.tokens,
                 "promptTokens": model.promptTokens,
                 "completionTokens": model.completionTokens,
                 "cost": model.cost as Any]
            },
        ]
        payload["cost"] = stats.cost as Any
        if let peak = stats.peakDay {
            payload["peakDay"] = ISO.string(from: peak)
        }
        if let days, days > 0 {
            payload["days"] = stats.recentDays(min(days, 366)).map { day -> [String: Any] in
                ["date": ISO.string(from: day.id), "tokens": day.tokens, "turns": day.turns,
                 "byModel": day.byModel]
            }
        }
        return payload
    }

    private static func suggest(query: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let model = AddressSuggestionsModel()
        // build() 带 100ms 防抖（击键路径专用）——桥同步读会拿到空数组。
        model.buildImmediate(query: query, settings: app.settings,
                             bookmarks: app.bookmarkStore, history: app.historyStore)
        return ["suggestions": model.suggestions.map { s -> [String: Any] in
            ["kind": s.kind.rawValue, "title": s.title, "url": s.url]
        }]
    }

    /// Adds a bookmark (test seed for suggestion ranking). Write goes through
    /// the live AppState store.
    private static func addBookmark(title: String, url: String) throws -> [String: Any] {
        guard let app = AppState.live, !url.isEmpty else { return ["error": "missing url"] }
        app.bookmarkStore.add(title: title.isEmpty ? url : title, url: url)
        return ["ok": true, "count": app.bookmarkStore.leafEntries.count]
    }

    /// Removes a bookmark by URL (test cleanup). Live store — write-safe.
    private static func removeBookmark(id: UUID) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard app.bookmarkStore.remove(id: id) else {
            return ["error": "no such bookmark"]
        }
        return ["ok": true]
    }

    private static func removeBookmark(url: String) throws -> [String: Any] {
        guard let app = AppState.live, !url.isEmpty else { return ["error": "missing url"] }
        guard let bookmark = app.bookmarkStore.find(url: url) else {
            return ["error": "no such bookmark"]
        }
        app.bookmarkStore.remove(bookmark)
        return ["ok": true]
    }

    /// 书签导入（去重向导的程序化孪生，Netscape HTML 格式）：`html` 或
    /// `path` 二选一；`dryRun` 只回计划（向导同款统计 + 重复样例）；
    /// 落库时 `strategy` = skipDuplicates（默认，只进全新条目）/ keepAll。
    /// 面板向导走同一套 BookmarkImportDedupe 逻辑。
    private static func importBookmarksBridge(
        html: String?, path: String?, strategy: String, dryRun: Bool
    ) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        var source = html
        if source == nil, let path, !path.isEmpty {
            source = try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard let text = source, !text.isEmpty else { return ["error": "missing html or path"] }
        let parsed = BookmarkImportService.parseHTMLBookmarks(text)
        guard !parsed.isEmpty else { return ["error": "no bookmarks parsed"] }
        let plan = BookmarkImportDedupe.plan(incoming: parsed,
                                             existingURLs: app.bookmarkStore.importedURLSet())
        var payload: [String: Any] = [
            "ok": true,
            "dryRun": dryRun,
            "total": plan.total,
            "fresh": plan.fresh,
            "existingDuplicates": plan.existingDuplicates.count,
            "innerDuplicates": plan.innerDuplicates.count,
        ]
        if dryRun {
            payload["sample"] = (plan.existingDuplicates + plan.innerDuplicates).prefix(20).map {
                ["title": $0.title, "url": $0.url, "kind": $0.kind.rawValue]
            }
            payload["freshSample"] = Array(plan.filtered.flatMap { $0.flattened().map(\.0) }
                .filter { $0.isLeaf }.prefix(20).map { ["title": $0.title, "url": $0.url ?? ""] })
        } else {
            let toImport = strategy == "keepAll" ? parsed : plan.filtered
            app.bookmarkStore.saveImported(toImport)
            payload["imported"] = BookmarkImportDedupe.leafCount(toImport)
        }
        return payload
    }

    // MARK: Pins / reading list / search history

    private static func setPin(index: Int?, pinned: Bool?) throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        tab.isPinned = pinned ?? !tab.isPinned
        return ["ok": true, "index": index ?? -1, "pinned": tab.isPinned]
    }

    /// 写阅读进度（E2E/自动化用；盖 LWW 戳随同步，与页内采集同一条路径）。
    private static func setReadingProgress(url: String, ratio: Double) throws -> [String: Any] {
        guard let app = AppState.live, !url.isEmpty else { return ["error": "missing url"] }
        guard app.readingListStore.items.contains(where: { $0.url == url }) else {
            return ["error": "no such reading-list item"]
        }
        app.readingListStore.setProgress(ratio, for: url)
        return ["ok": true, "url": url,
                "progress": app.readingListStore.progress(for: url) ?? 0]
    }

    private static func readingList() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        return ["items": app.readingListStore.items.map { i -> [String: Any] in
            var row: [String: Any] = ["id": i.id.uuidString, "title": i.title, "url": i.url, "read": i.isRead]
            if let cached = app.readingListStore.cacheURL(for: i.id) {
                row["cached"] = true
                row["cachedPath"] = cached.path
            } else {
                row["cached"] = false
            }
            if let summary = i.summary { row["summary"] = summary }
            if let progress = i.progress { row["progress"] = progress }
            return row
        }]
    }

    /// 窗口级工作区（v22 桥面）：列表 + 按名删除——E2E 清理与外部驱动用。
    private static func workspacesList() -> [String: Any] {
        let items = WorkspaceStore.shared.workspaces.map { ws -> [String: Any] in
            ["name": ws.name, "tabs": ws.session.tabs.count,
             "savedAt": ISO8601DateFormatter().string(from: ws.savedAt)]
        }
        return ["ok": true, "workspaces": items]
    }

    /// 归档会话（v27 桥面）：列表 / 恢复到指定窗口 / 删除。
    private static func sessionArchivesList() -> [String: Any] {
        let entries = SessionArchive.list(in: TabSessionCoordinator.archiveDirectory)
        let iso = ISO8601DateFormatter()
        return ["ok": true, "archives": entries.map { e -> [String: Any] in
            ["file": e.fileName, "savedAt": iso.string(from: e.savedAt),
             "tabs": e.tabCount, "urls": e.topURLs]
        }]
    }

    private static func sessionArchiveRestore(file: String, window: String?) -> [String: Any] {
        guard let session = Self.resolveSession(window),
              let manager = session.boundTabManager,
              let app = AppState.live else {
            return ["ok": false, "error": "no live window (pass window=<agent session id>?)"]
        }
        guard let tabs = TabSessionCoordinator.shared.restoreArchivedSession(
            named: file, into: manager,
            settings: app.settings, contentBlocker: app.contentBlocker,
            videoAdBlocker: app.videoAdBlocker) else {
            return ["ok": false, "error": "bad archive file: \(file)"]
        }
        return ["ok": true, "tabs": tabs,
                "urls": manager.tabs.map { $0.urlString }.filter { !$0.isEmpty }]
    }

    private static func sessionArchiveDelete(file: String) -> [String: Any] {
        let removed = TabSessionCoordinator.shared.removeArchivedSession(named: file)
        return removed ? ["ok": true, "deleted": file] : ["ok": false, "error": "bad or missing file: \(file)"]
    }

    /// 朗读状态（v0.7.18）：自动化/E2E 观察端上 TTS（readAloud 与阅读模式共用）。
    private static func speechState() -> [String: Any] {
        ["speaking": ReaderSpeechService.shared.isSpeaking,
         "paused": ReaderSpeechService.shared.isPaused]
    }

    /// 会话预算快照（v0.7.18，GET /agent/budget）——交付目标会话的口径。
    private static func agentBudget(window: String?) -> [String: Any] {
        guard let session = resolveSession(window) else { return ["error": "no live agent session"] }
        return session.budgetSnapshot()
    }

    /// 收件箱（v26）：与 Agent 窗口收件箱页同一份构建逻辑；会话按"查询读盘"
    /// 惯例走新实例（UI 用实时 store，两边语义一致、输入来源不同）。
    private static func agentInbox() -> [String: Any] {
        let dismissals = AgentInboxDismissalStore.shared
        dismissals.purgeExpired()
        let sections = AgentInbox.build(AgentInboxCollector.diskInputs(),
                                        hidden: { dismissals.isHidden($0) })
            .filter { !$0.items.isEmpty }
        let json: [[String: Any]] = sections.map { section in
            ["id": section.id, "title": section.title,
             "items": section.items.map { item -> [String: Any] in
                 var row: [String: Any] = [
                     "id": item.id,
                     "kind": item.kind.rawValue, "title": item.title, "detail": item.detail,
                 ]
                 if let cid = item.conversationID { row["conversationId"] = cid.uuidString }
                 return row
             }]
        }
        return [
            "ok": true,
            "sections": json,
            "actionCount": AgentInbox.actionCount(sections),
            "totalCount": sections.reduce(0) { $0 + $1.items.count },
            "hiddenCount": dismissals.hiddenCount,
        ]
    }

    /// 标签组（v23 桥面）：列表 + 按名删除——测试清理与外部驱动用。
    /// 走 AppState.live 的实例（写操作必须落在 UI 持有的同一份状态上）。
    private static func tabGroupsList() -> [String: Any] {
        guard let store = AppState.live?.tabGroupStore else { return ["ok": false, "error": "app state not ready"] }
        let items: [[String: Any]] = store.groups.map { g in
            ["name": g.name, "colorIndex": g.colorIndex, "tabCount": g.tabIds.count,
             "collapsed": g.isCollapsed]
        }
        return ["ok": true, "groups": items]
    }

    private static func tabGroupDelete(name: String) -> [String: Any] {
        guard !name.isEmpty else { return ["ok": false, "error": "missing name"] }
        guard let store = AppState.live?.tabGroupStore else { return ["ok": false, "error": "app state not ready"] }
        guard let group = store.groups.first(where: { $0.name == name }) else {
            return ["ok": false, "error": "not found: \(name)"]
        }
        store.delete(group.id)
        return ["ok": true, "deleted": group.name]
    }

    private static func workspaceDelete(name: String) -> [String: Any] {
        guard !name.isEmpty else { return ["ok": false, "error": "missing name"] }
        guard let ws = WorkspaceStore.shared.workspace(named: name) else {
            return ["ok": false, "error": "not found: \(name)"]
        }
        WorkspaceStore.shared.remove(ws.id)
        return ["ok": true, "deleted": ws.name]
    }

    /// 阅读列表离线缓存（.webarchive）：页面已打开复用其 webview，否则后台加载。
    private static func readingListCacheAsync(url: String) async -> [String: Any] {
        guard let app = AppState.live, !url.isEmpty else { return ["error": "missing url"] }
        guard let item = app.readingListStore.items.first(where: { $0.url == url }) else {
            return ["error": "not in the reading list — POST /reading-list/add first"]
        }
        guard let outcome = await ReadingListCache.capture(url: url, itemID: item.id) else {
            return ["error": "offline capture failed (page never finished loading?)"]
        }
        app.readingListStore.setCache(item.id, fileURL: outcome.fileURL)
        return ["ok": true, "path": outcome.fileURL.path, "bytes": outcome.bytes,
                "fromOpenTab": outcome.fromOpenTab, "title": item.title]
    }

    private static func addReadingItem(title: String, url: String) throws -> [String: Any] {
        guard let app = AppState.live, !url.isEmpty else { return ["error": "missing url"] }
        app.readingListStore.add(title: title.isEmpty ? url : title, url: url)
        return ["ok": true, "count": app.readingListStore.items.count]
    }

    private static func removeReadingItem(url: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let item = app.readingListStore.items.first(where: { $0.url == url }) else {
            return ["error": "no such item"]
        }
        app.readingListStore.remove(item.id)
        return ["ok": true]
    }

    private static func searchHistory(count: Int) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        return ["queries": app.searchHistoryStore.recentQueries(count: count)]
    }

    private static func addSearchHistory(query: String, engine: String) throws -> [String: Any] {
        guard let app = AppState.live, !query.isEmpty else { return ["error": "missing query"] }
        app.searchHistoryStore.add(query: query, engine: engine)
        return ["ok": true]
    }

    private static func clearSearchHistory() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        app.searchHistoryStore.clearAll()
        return ["ok": true]
    }

    // MARK: Tab groups

    private static func organizeTabGroups() throws -> [String: Any] {
        guard let app = AppState.live,
              let tm = TabSessionCoordinator.shared.activeTabManager else {
            return ["error": "no active window"]
        }
        let count = TabOrganizer.shared.organize(tabs: tm.tabs, store: app.tabGroupStore)
        return ["ok": true, "groups": count,
                "canUndo": TabOrganizer.shared.canUndo]
    }

    private static func undoTabGroups() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        TabOrganizer.shared.undo(store: app.tabGroupStore)
        return ["ok": true]
    }

    private static func tabGroups() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        return ["groups": app.tabGroupStore.groups.map { g -> [String: Any] in
            ["name": g.name, "tabs": g.tabIds.count, "collapsed": g.isCollapsed]
        }]
    }

    private static func createTabGroup(name: String, tabIndex: Int?) throws -> [String: Any] {
        guard let app = AppState.live, let tm = try shared.tabManager, !name.isEmpty else {
            return ["error": "missing name or no tab manager"]
        }
        let group = app.tabGroupStore.create(name: name)
        if let index = tabIndex, tm.tabs.indices.contains(index) {
            app.tabGroupStore.addTab(tm.tabs[index].id, to: group.id)
        }
        return ["ok": true, "name": group.name]
    }

    private static func collapseTabGroup(name: String, collapsed: Bool) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let group = app.tabGroupStore.groups.first(where: { $0.name == name }) else {
            return ["error": "no such group"]
        }
        app.tabGroupStore.setCollapsed(group.id, collapsed)
        return ["ok": true, "collapsed": collapsed]
    }

    private static func deleteTabGroup(name: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let group = app.tabGroupStore.groups.first(where: { $0.name == name }) else {
            return ["error": "no such group"]
        }
        app.tabGroupStore.delete(group.id)
        return ["ok": true]
    }

    /// Removes a container by name (test cleanup). Write goes through
    /// ContainerStore.shared — the UI's live instance.
    private static func removeContainer(_ name: String) throws -> [String: Any] {
        guard let container = ContainerStore.shared.containers.first(where: { $0.name == name }) else {
            return ["error": "no such container"]
        }
        ContainerStore.shared.removeContainer(container.id)
        return ["ok": true]
    }

    /// Keyboard-shortcut bindings: drives the customize → live-menu pipeline
    /// end to end without touching the Settings UI. Also introspects the real
    /// NSMenu items, so a test can assert that a re-recording actually
    /// re-bound the menu accelerator (what physical keypresses match against).
    private static func removeMCPServer(name: String) throws -> [String: Any] {
        let store = MCPStore.shared
        guard let server = store.servers.first(where: { $0.name == name }) else {
            return ["error": "no such server"]
        }
        store.removeServer(server.id)
        return ["ok": true]
    }

    private static func addMCPStdioServer(name: String, command: String) throws -> [String: Any] {
        MCPStore.shared.addStdioServer(name: name, command: command)
        guard let server = MCPStore.shared.servers.first(where: { $0.command != nil }) else {
            return ["error": "invalid name/command"]
        }
        return ["ok": true, "id": server.id.uuidString, "transport": "stdio"]
    }

    private static func addMCPServer(name: String, url: String) throws -> [String: Any] {
        guard !name.isEmpty, !url.isEmpty else { return ["error": "missing name or url"] }
        MCPStore.shared.addServer(name: name, url: url)
        return ["ok": true]
    }

    private static func reconnectMCPServer(name: String) throws -> [String: Any] {
        guard let server = MCPStore.shared.servers.first(where: { $0.name == name }) else {
            return ["error": "no such server"]
        }
        MCPStore.shared.reconnect(server.id)
        return ["ok": true]
    }

    private static func shortcuts() throws -> [String: Any] {        guard let store = AppState.live?.system.keyboardShortcutStore else {
            return ["error": "store not ready"]
        }
        let rows = store.shortcuts.map { m -> [String: Any] in
            ["id": m.id, "key": m.keyEquivalent, "modifierFlags": m.modifierFlags,
             "customized": m.isCustomized, "command": m.commandName]
        }
        var menu: [String: Any] = [:]
        for item in NSApp.mainMenu?.items ?? [] {
            for child in item.submenu?.items ?? [] where !child.keyEquivalent.isEmpty {
                menu[child.title] = ["key": child.keyEquivalent,
                                     "modifiers": child.keyEquivalentModifierMask.rawValue]
            }
        }
        return ["shortcuts": rows, "menu": menu]
    }

    private static func updateShortcut(id: String, key: String, modifierFlags: UInt) throws -> [String: Any] {
        guard let store = AppState.live?.system.keyboardShortcutStore else {
            return ["error": "store not ready"]
        }
        guard var mapping = store.shortcuts.first(where: { $0.id == id }) else {
            return ["error": "unknown shortcut id"]
        }
        mapping.keyEquivalent = key
        mapping.modifierFlags = modifierFlags
        if store.findConflicts(mapping: mapping).isEmpty {
            store.update(mapping)
            return ["ok": true, "id": id, "key": key, "modifierFlags": modifierFlags]
        }
        return ["error": "conflict", "conflicts": store.findConflicts(mapping: mapping).map(\.id)]
    }

    /// Resolves a pending approval: decision ∈ allow_once | always_allow | deny.
    /// Lets external test drivers exercise the dangerous-tool path end to
    /// end without a human click.
    private static func resolvePendingApproval(_ decision: String, window: String? = nil, siteGrant: Bool = false) throws -> [String: Any] {
        guard let session = resolveSession(window), session.pendingApproval != nil else {
            return ["error": "no pending approval"]
        }
        let outcome: ApprovalDecision
        switch decision {
        case "allow_once": outcome = .allowOnce
        case "always_allow": outcome = .alwaysAllow
        case "deny": outcome = .deny
        default: return ["error": "decision must be allow_once | always_allow | deny"]
        }
        ApprovalPolicyStore.shared.recordHistory(
            toolName: session.pendingApproval?.toolCall.function.name ?? "unknown",
            decision: decision, source: "bridge")
        // siteGrant 必须**传下去**：DPP 逐动作审批的「本站始终允许」由
        // store 的 resolveApproval(siteGrant:) 落成 站点×动作 规则——
        // 此前这里收了参数却没转发，桥的显式站点授权静默退化成普通放行
        // （2026-10-17 修，gate_e2e D 轮照出）。
        session.resolveApproval(outcome, siteGrant: siteGrant)
        return ["ok": true, "resolved": decision]
    }

    /// 轨迹导出：一行一个回合的 JSONL（从会话派生，含每个工具的耗时）。
    @MainActor
    private static func agentTrace(conversation: String?, limit: Int?) -> [String: Any] {
        // R2-7：内存 store 优先；内存里没有（如按 id 找已落盘但未加载的）才
        // 落盘新实例兜底。
        let liveStore = AppState.live?.conversationStore
        let store = liveStore ?? ConversationStore()
        var target: Conversation?
        if let conversation, let id = UUID(uuidString: conversation) {
            target = store.conversations.first { $0.id == id }
        } else if let id = AgentScheduler.shared.deliveryTarget?.conversationId {
            target = store.conversations.first { $0.id == id }
        }
        if target == nil, let conversation, let id = UUID(uuidString: conversation) {
            // 内存里没有 → 落盘兜底（可能已从会话列表删除但文件还在）。
            let diskStore = ConversationStore()
            target = diskStore.conversations.first { $0.id == id }
        }
        guard let target else {
            return ["error": "no such conversation (pass ?conversation=<uuid> from /conversations/search)"]
        }
        // 成本：单价来自设置里的模型单价表；**没填价就只有 token、没有金额**。
        let preference = AppState.live?.aiPreference
        let price: (String?) -> ModelPrice? = { model in preference?.usagePrice(for: model) }
        let turns = AgentTrace.turns(of: target, price: price)
        let scoped = limit.map { $0 > 0 ? Array(turns.suffix($0)) : turns } ?? turns
        let jsonl = scoped.compactMap { turn -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: turn, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        var payload: [String: Any] = ["conversation": target.id.uuidString, "title": target.title,
                                      "turns": scoped.count, "stats": AgentTrace.stats(of: turns),
                                      "jsonl": jsonl]
        // 每条消息各自的用量（面板状态行同一套算法），方便脚本按消息对账。
        let usage = AgentUsage.of(target.messages, price: price)
        if !usage.isEmpty {
            payload["usage"] = ["promptTokens": usage.promptTokens,
                                "completionTokens": usage.completionTokens,
                                "totalTokens": usage.totalTokens,
                                "cost": usage.usd as Any,
                                "costIncomplete": usage.hasUnpriced]
        }
        return payload
    }

    /// 给某条助手消息投票（👍/👎），用于自动化的评价采集。
    @MainActor
    private static func setAgentFeedback(messageId: String, vote: String) -> [String: Any] {
        guard let session = AgentScheduler.shared.deliveryTarget else {
            return ["error": "no live agent session"]
        }
        guard let id = UUID(uuidString: messageId) else {
            return ["error": "messageId must be a UUID (see /agent/messages)"]
        }
        let normalized: String? = (vote == "up" || vote == "down") ? vote : nil
        // 先在活动会话里找（UI 走的就是这条）；找不到就落到**已存盘的会话**——
        // 否则对一个已关闭的会话投票会静默无效，而端点却报 ok。
        if session.setFeedback(normalized, for: id) {
            return ["ok": true, "messageId": messageId, "vote": normalized ?? "none", "scope": "live"]
        }
        let store = AppState.live?.conversationStore ?? ConversationStore()
        guard let conversation = store.conversations.first(where: { conv in
            conv.messages.contains { $0.id == id }
        }) else {
            return ["error": "no message with that id (live session or saved conversations)"]
        }
        var updated = conversation
        guard let index = updated.messages.firstIndex(where: { $0.id == id }) else {
            return ["error": "message vanished"]
        }
        updated.messages[index].feedback = normalized
        store.save(updated)
        return ["ok": true, "messageId": messageId, "vote": normalized ?? "none", "scope": "saved"]
    }

    /// 恢复：为会话末尾**未获回答的用户提问**直接开一轮（不重复入列）。
    @MainActor
    private static func agentResume(window: String?) -> [String: Any] {
        guard let session = resolveSession(window) else { return ["error": "no live agent session"] }
        guard !session.isProcessing else { return ["error": "a turn is already running"] }
        let resumed = session.resumeLastPrompt()
        return resumed ? ["ok": true, "resumed": true]
                       : ["ok": false, "reason": "the trailing message is not an unanswered user prompt"]
    }

    private static func agentMessages(window: String? = nil) throws -> [String: Any] {
        guard let session = resolveSession(window) else {
            return ["error": "no live agent session"]
        }
        let messages = session.messages.suffix(12).map { message -> [String: Any] in
            var item: [String: Any] = ["id": message.id.uuidString, "role": message.role.rawValue]
            if let content = message.content { item["content"] = String(content.prefix(2000)) }
            if let reasoning = message.reasoning { item["reasoning"] = String(reasoning.prefix(600)) }
            if let critique = message.critique { item["critique"] = String(critique.prefix(600)) }
            if let note = message.verificationNote { item["verificationNote"] = String(note.prefix(600)) }
            if let feedback = message.feedback { item["feedback"] = feedback }
            if let calls = message.toolCalls { item["toolCalls"] = calls.map(\.function.name) }
            // 成本/路由审计（v0.7.26）：模型、路由原因、token 用量都在消息上，
            // 桥透传它们，成本与路由的 E2E 才能只读断言。
            if let model = message.model { item["model"] = model }
            if let route = message.routeReason { item["routeReason"] = route }
            if let prompt = message.promptTokens { item["promptTokens"] = prompt }
            if let completion = message.completionTokens { item["completionTokens"] = completion }
            return item
        }
        return [
            "messages": Array(messages),
            "busy": session.isProcessing,
            "hasInterruptedTurn": session.hasInterruptedTurn,
            "directive": session.activeDirective ?? "",
            // 输入历史（按对话保存，面板 ↑/↓ 翻阅的那份）
            "inputHistory": Array(session.inputHistory.suffix(20)),
        ]
    }

    /// Resolves the target session: explicit `window` UUID wins, else the
    /// newest registered session (scheduler delivery target).
    private static func resolveSession(_ window: String?) -> AgentSessionStore? {
        if let window, let id = UUID(uuidString: window) {
            return AgentScheduler.shared.session(withID: id)
        }
        return AgentScheduler.shared.deliveryTarget
    }

    /// 会话接力（v0.7.25）：源（当前投递会话）先落盘 → 目标 loadConversation →
    /// 投递目标切到目标 → 源 clear() 回空会话（不持有旧对话，避免退出时旧副本
    /// 覆盖目标的新内容）。
    private static func agentHandoff(window: String?) -> [String: Any] {
        guard let window, let targetID = UUID(uuidString: window),
              let target = AgentScheduler.shared.session(withID: targetID) else {
            return ["error": "handoff needs window=<live session id> (see GET /agent/windows)"]
        }
        guard let source = AgentScheduler.shared.deliveryTarget, source !== target else {
            return ["error": "source session is missing or already the target"]
        }
        guard let conversation = source.conversationId else {
            return ["error": "source session has no conversation to hand off"]
        }
        source.flushConversation()
        target.loadConversation(conversation)
        AgentScheduler.shared.deliveryTarget = target
        source.clear()
        return ["ok": true, "conversation": conversation.uuidString,
                "target": targetID.uuidString]
    }

    private static func agentWindows() throws -> [String: Any] {
        let windows = AgentScheduler.shared.liveSessions().map { entry -> [String: Any] in
            guard let session = entry.store else { return ["id": entry.id.uuidString] }
            return [
                "id": entry.id.uuidString,
                "label": entry.windowTitle ?? entry.displayLabel,
                "busy": session.isProcessing,
                "pendingApproval": session.pendingApproval != nil,
                "messages": session.messages.count,
                "isNewest": AgentScheduler.shared.deliveryTarget === session,
                // 宿主窗口是否真实可见（关掉的窗口会滞留为不可见窗口，会话
                // 条目一时半会不消失——窗口活性要以这个为准）。**扫全部标签**：
                // 挂起标签没有挂到窗口上的 webview，只看 selectedTab 会误报
                // 不可见（实测把刚开出来的新窗口判成"没开"）。
                "windowVisible": session.boundTabManager?.tabs.contains { tab in
                    tab.browser.webView.window?.isVisible == true
                } ?? false,
                // 双窗口互不串台的断言面：每窗会话当前装载的对话
                "conversationId": session.conversationId?.uuidString ?? "",
                "conversationTitle": session.conversationTitle ?? "",
                "model": session.modelProfileName ?? "",
                "mode": session.effectiveMode.rawValue,
                "hasInterruptedTurn": session.hasInterruptedTurn,
            ]
        }
        return ["windows": windows]
    }

    /// 已保存的元素屏蔽规则（按 host 过滤可选）。
    private static func adRules(host: String?) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let host = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = app.elementBlockStore.rules.filter { rule in
            guard let host, !host.isEmpty else { return true }
            return rule.urlPattern == host
        }
        return [
            "total": app.elementBlockStore.rules.count,
            "rules": rules.map { ["id": $0.id.uuidString, "urlPattern": $0.urlPattern, "cssSelector": $0.cssSelector] },
        ]
    }

    /// 撤掉某 host 的元素屏蔽规则（不传 host = 清空全部）。
    private static func adRulesClear(host: String?) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let host = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let doomed = app.elementBlockStore.rules.filter { rule in
            guard let host, !host.isEmpty else { return true }
            return rule.urlPattern == host
        }
        for rule in doomed { app.elementBlockStore.remove(id: rule.id) }
        return ["ok": true, "removed": doomed.count, "total": app.elementBlockStore.rules.count]
    }

    // MARK: - 运营工作台（0.7.15；与 Agent 工具、slash /promote 同源）

    private static func promotionState() -> [String: Any] {
        let store = PromotionStore.shared
        let progress = PromotionSummary.progress(goals: store.goals, posts: store.posts)
        return [
            "goals": store.goals.map { goalJSON($0) },
            "posts": store.posts.map { postJSON($0) },
            "accounts": store.accounts.map { promotionAccountJSON($0) },
            "lessons": store.lessons.map { promotionLessonJSON($0) },
            "interactions": store.interactions.map { promotionInteractionJSON($0) },
            "pendingInteractions": store.pendingInteractionCount,
            "progress": progress.map { p -> [String: Any] in
                [
                    "goalID": p.goalID.uuidString, "title": p.title,
                    "domain": p.domain.rawValue,
                    "published": p.publishedCount, "drafts": p.draftCount,
                    "target": p.target ?? 0, "isComplete": p.isComplete,
                    "isOverdue": p.isOverdue,
                ]
            },
            "digest": store.digest(),
        ]
    }

    private static func promotionGoalAdd(_ body: [String: Any]) -> [String: Any] {
        guard let title = string(body, "title"), !title.isEmpty else { return ["error": "missing title"] }
        let target = (body["targetPosts"] as? Int) ?? (body["targetPosts"] as? Double).map(Int.init)
        let domain = (string(body, "domain")).flatMap { OperationDomain(rawValue: $0.lowercased()) } ?? .promotion
        guard let goal = PromotionStore.shared.addGoal(
            title: title,
            objective: string(body, "objective") ?? "",
            domain: domain,
            platforms: (body["platforms"] as? [String]) ?? [],
            targetPosts: target,
            dueDate: promotionDate(string(body, "dueDate"))) else {
            return ["error": "title is empty"]
        }
        return ["ok": true, "goal": goalJSON(goal)]
    }

    private static func promotionGoalRemove(_ body: [String: Any]) -> [String: Any] {
        guard let id = string(body, "id"), let uuid = UUID(uuidString: id) else {
            return ["error": "missing or invalid id"]
        }
        let existed = PromotionStore.shared.goals.contains { $0.id == uuid }
        PromotionStore.shared.removeGoal(uuid)
        return ["ok": existed]
    }

    private static func promotionPostSave(_ body: [String: Any]) -> [String: Any] {
        let statusRaw = (string(body, "status") ?? "draft").lowercased()
        guard let status = PromotionPost.Status(rawValue: statusRaw) else {
            return ["error": "status must be idea, draft or published"]
        }
        var plannedFor: Date?? = nil
        if let plannedRaw = body["plannedFor"] as? String {
            if plannedRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plannedFor = .some(nil)
            } else if let parsed = promotionDate(plannedRaw) {
                plannedFor = .some(parsed)
            } else {
                return ["error": "plannedFor must be yyyy-MM-dd (or ISO8601)"]
            }
        }
        // 带 id = 更新既有帖子（选题→草稿、改排期、补 URL）。
        if let idRaw = string(body, "id"), !idRaw.isEmpty {
            guard let uuid = UUID(uuidString: idRaw) else { return ["error": "invalid id"] }
            let goalText = string(body, "goal")
            guard let updated = PromotionStore.shared.updatePost(
                id: uuid,
                goalText: goalText.map { Optional($0) },
                platform: string(body, "platform"),
                title: string(body, "title"),
                body: string(body, "body"),
                status: status,
                url: string(body, "url"),
                plannedFor: plannedFor) else {
                return ["error": "no post matches \(idRaw)"]
            }
            return ["ok": true, "id": updated.id.uuidString, "status": updated.status.rawValue,
                    "post": postJSON(updated)]
        }
        guard let platform = string(body, "platform"), !platform.isEmpty else { return ["error": "missing platform"] }
        guard let title = string(body, "title"), !title.isEmpty else { return ["error": "missing title"] }
        let text = string(body, "body") ?? ""
        if status != .idea, text.isEmpty { return ["error": "missing body (required for draft/published)"] }
        let outcome = PromotionStore.shared.savePost(
            goalText: string(body, "goal"), platform: platform, title: title,
            body: text, status: status, url: string(body, "url"),
            plannedFor: plannedFor.flatMap { $0 })
        var out: [String: Any] = [
            "ok": true, "id": outcome.post.id.uuidString,
            "status": outcome.post.status.rawValue, "post": postJSON(outcome.post),
        ]
        if let goal = outcome.matchedGoalTitle { out["goalTitle"] = goal }
        if outcome.goalMissed { out["goalMissed"] = true }
        return out
    }

    /// 运营周报（与 promotionReport 工具、面板复制同源）。
    private static func promotionReport(_ query: [String: String]) -> [String: Any] {
        let store = PromotionStore.shared
        let days = Int(query["periodDays"] ?? "") ?? 7
        let markdown = PromotionReport.markdown(
            goals: store.goals, posts: store.posts,
            accounts: store.accounts, lessons: store.lessons,
            interactions: store.interactions,
            periodDays: max(1, days))
        return ["markdown": markdown]
    }

    private static func promotionMetricsSave(_ body: [String: Any]) -> [String: Any] {
        guard let idOrURL = string(body, "idOrURL"), !idOrURL.isEmpty else {
            return ["error": "missing idOrURL"]
        }
        let views = (body["views"] as? Int) ?? (body["views"] as? Double).map(Int.init)
        let likes = (body["likes"] as? Int) ?? (body["likes"] as? Double).map(Int.init)
        let comments = (body["comments"] as? Int) ?? (body["comments"] as? Double).map(Int.init)
        guard views != nil || likes != nil || comments != nil else {
            return ["error": "provide at least one of views/likes/comments"]
        }
        guard let post = PromotionStore.shared.recordMetrics(
            idOrURL: idOrURL, views: views, likes: likes, comments: comments) else {
            return ["error": "no post matches \(idOrURL)"]
        }
        return ["ok": true, "post": postJSON(post)]
    }

    private static func promotionPostRemove(_ body: [String: Any]) -> [String: Any] {
        guard let id = string(body, "id"), let uuid = UUID(uuidString: id) else {
            return ["error": "missing or invalid id"]
        }
        let existed = PromotionStore.shared.posts.contains { $0.id == uuid }
        PromotionStore.shared.removePost(uuid)
        return ["ok": existed]
    }

    private static func promotionAccountSave(_ body: [String: Any]) -> [String: Any] {
        guard let platform = string(body, "platform"), !platform.isEmpty else { return ["error": "missing platform"] }
        guard let handle = string(body, "handle"), !handle.isEmpty else { return ["error": "missing handle"] }
        let domain = (string(body, "domain")).flatMap { OperationDomain(rawValue: $0.lowercased()) } ?? .media
        guard let account = PromotionStore.shared.saveAccount(
            domain: domain, platform: platform, handle: handle,
            url: string(body, "url"), note: string(body, "note") ?? "") else {
            return ["error": "platform and handle must not be empty"]
        }
        return ["ok": true, "account": promotionAccountJSON(account)]
    }

    private static func promotionAccountMetricsSave(_ body: [String: Any]) -> [String: Any] {
        guard let idOrHandle = string(body, "idOrHandle"), !idOrHandle.isEmpty else {
            return ["error": "missing idOrHandle"]
        }
        let followers = (body["followers"] as? Int) ?? (body["followers"] as? Double).map(Int.init)
        let views = (body["views"] as? Int) ?? (body["views"] as? Double).map(Int.init)
        let likes = (body["likes"] as? Int) ?? (body["likes"] as? Double).map(Int.init)
        guard followers != nil || views != nil || likes != nil else {
            return ["error": "provide at least one of followers/views/likes"]
        }
        guard let account = PromotionStore.shared.recordAccountMetrics(
            idOrHandle: idOrHandle, followers: followers, views: views, likes: likes) else {
            return ["error": "no account matches \(idOrHandle)"]
        }
        return ["ok": true, "account": promotionAccountJSON(account)]
    }

    private static func promotionAccountRemove(_ body: [String: Any]) -> [String: Any] {
        guard let id = string(body, "id"), let uuid = UUID(uuidString: id) else {
            return ["error": "missing or invalid id"]
        }
        let existed = PromotionStore.shared.accounts.contains { $0.id == uuid }
        PromotionStore.shared.removeAccount(uuid)
        return ["ok": existed]
    }

    private static func promotionLessonAdd(_ body: [String: Any]) -> [String: Any] {
        guard let text = string(body, "text"), !text.isEmpty else { return ["error": "missing text"] }
        let domain = (string(body, "domain")).flatMap { OperationDomain(rawValue: $0.lowercased()) }
        guard let lesson = PromotionStore.shared.addLesson(
            text: text, domain: domain, platform: string(body, "platform"), source: .agent) else {
            return ["ok": false, "skipped": "empty or duplicate"]
        }
        return ["ok": true, "lesson": promotionLessonJSON(lesson)]
    }

    private static func promotionLessonRemove(_ body: [String: Any]) -> [String: Any] {
        guard let id = string(body, "id"), let uuid = UUID(uuidString: id) else {
            return ["error": "missing or invalid id"]
        }
        let existed = PromotionStore.shared.lessons.contains { $0.id == uuid }
        PromotionStore.shared.removeLesson(uuid)
        return ["ok": existed]
    }

    /// 运营定时任务：kind=dailyCollect|weeklyReview（默认 weeklyReview），
    /// action=schedule（默认，幂等重建）/ remove。名字与提示词走
    /// PromotionAutomation 单一定义（面板同源）。
    private static func promotionReview(_ body: [String: Any]) -> [String: Any] {
        let kindRaw = string(body, "kind") ?? "weeklyReview"
        guard let kind = PromotionAutomation.Kind(rawValue: kindRaw) else {
            return ["error": "kind must be dailyCollect or weeklyReview"]
        }
        if (string(body, "action") ?? "schedule") == "remove" {
            PromotionAutomation.remove(kind)
            return ["ok": true, "scheduled": false, "kind": kind.rawValue]
        }
        guard PromotionAutomation.schedule(kind) else {
            return ["error": "failed to schedule"]
        }
        let task = AgentScheduler.shared.tasks.first { $0.name == kind.taskName }
        return ["ok": true, "scheduled": true, "kind": kind.rawValue,
                "task": kind.taskName, "recurrence": task?.recurrenceText ?? ""]
    }

    private static func promotionAccountJSON(_ account: PromotionAccount) -> [String: Any] {
        var out: [String: Any] = [
            "id": account.id.uuidString, "domain": account.domain.rawValue,
            "platform": account.platform, "handle": account.handle,
            "note": account.note, "isActive": account.isActive,
            "createdAt": account.createdAt.timeIntervalSince1970,
            "snapshots": account.snapshots.count,
        ]
        if let url = account.url { out["url"] = url }
        if let latest = account.latest {
            var latestJSON: [String: Any] = ["at": latest.at.timeIntervalSince1970]
            if let f = latest.followers { latestJSON["followers"] = f }
            if let v = latest.views { latestJSON["views"] = v }
            if let l = latest.likes { latestJSON["likes"] = l }
            out["latest"] = latestJSON
        }
        if let growth = account.followersGrowth { out["followersGrowth"] = growth }
        return out
    }

    /// 互动登记：单条（顶层字段）或批量（items 数组）——批量是巡检主路径。
    private static func promotionInteractionLog(_ body: [String: Any]) -> [String: Any] {
        var drafts: [PromotionInteraction] = []
        if let items = body["items"] as? [[String: Any]] {
            for (idx, item) in items.prefix(50).enumerated() {
                guard let platform = string(item, "platform"), !platform.isEmpty else {
                    return ["error": "items[\(idx)] missing platform"]
                }
                guard let text = string(item, "text"), !text.isEmpty else {
                    return ["error": "items[\(idx)] missing text"]
                }
                drafts.append(promotionInteractionDraft(item, platform: platform, text: text))
            }
        } else {
            guard let platform = string(body, "platform"), !platform.isEmpty else {
                return ["error": "missing platform (or items array)"]
            }
            guard let text = string(body, "text"), !text.isEmpty else {
                return ["error": "missing text"]
            }
            drafts.append(promotionInteractionDraft(body, platform: platform, text: text))
        }
        let added = PromotionStore.shared.logInteractions(drafts)
        return ["ok": true, "added": added, "skipped": drafts.count - added,
                "pending": PromotionStore.shared.pendingInteractionCount]
    }

    private static func promotionInteractionDraft(_ item: [String: Any], platform: String,
                                                  text: String) -> PromotionInteraction {
        let kind = (string(item, "kind")).flatMap { PromotionInteraction.Kind(rawValue: $0.lowercased()) } ?? .comment
        return PromotionInteraction(
            kind: kind, platform: platform,
            accountHandle: string(item, "accountHandle"),
            postTitle: string(item, "postTitle"),
            postURL: string(item, "postURL"),
            author: string(item, "author") ?? "?",
            text: text,
            url: string(item, "url"))
    }

    private static func promotionInteractionReply(_ body: [String: Any]) -> [String: Any] {
        guard let id = string(body, "id"), let uuid = UUID(uuidString: id) else {
            return ["error": "missing or invalid id"]
        }
        var status: PromotionInteraction.Status?
        if let statusRaw = string(body, "status") {
            guard let parsed = PromotionInteraction.Status(rawValue: statusRaw.lowercased()) else {
                return ["error": "status must be replied, ignored or pending"]
            }
            status = parsed
        }
        guard let updated = PromotionStore.shared.replyInteraction(
            id: uuid, reply: string(body, "reply"), status: status) else {
            return ["error": "no interaction matches \(id)"]
        }
        return ["ok": true, "interaction": promotionInteractionJSON(updated)]
    }

    private static func promotionInteractionRemove(_ body: [String: Any]) -> [String: Any] {
        guard let id = string(body, "id"), let uuid = UUID(uuidString: id) else {
            return ["error": "missing or invalid id"]
        }
        let existed = PromotionStore.shared.interactions.contains { $0.id == uuid }
        PromotionStore.shared.removeInteraction(uuid)
        return ["ok": existed]
    }

    private static func promotionInteractionJSON(_ item: PromotionInteraction) -> [String: Any] {
        var out: [String: Any] = [
            "id": item.id.uuidString, "kind": item.kind.rawValue,
            "platform": item.platform, "author": item.author, "text": item.text,
            "status": item.status.rawValue,
            "createdAt": item.createdAt.timeIntervalSince1970,
        ]
        if let v = item.accountHandle { out["accountHandle"] = v }
        if let v = item.postTitle { out["postTitle"] = v }
        if let v = item.postURL { out["postURL"] = v }
        if let v = item.url { out["url"] = v }
        if let v = item.reply { out["reply"] = v }
        if let v = item.repliedAt { out["repliedAt"] = v.timeIntervalSince1970 }
        return out
    }

    private static func promotionLessonJSON(_ lesson: PromotionLesson) -> [String: Any] {
        var out: [String: Any] = [
            "id": lesson.id.uuidString, "text": lesson.text,
            "source": lesson.source.rawValue,
            "createdAt": lesson.createdAt.timeIntervalSince1970,
        ]
        if let domain = lesson.domain { out["domain"] = domain.rawValue }
        if let platform = lesson.platform { out["platform"] = platform }
        return out
    }

    private static func goalJSON(_ goal: PromotionGoal) -> [String: Any] {
        var out: [String: Any] = [
            "id": goal.id.uuidString, "title": goal.title, "objective": goal.objective,
            "domain": goal.domain.rawValue,
            "platforms": goal.platforms, "isActive": goal.isActive,
            "createdAt": goal.createdAt.timeIntervalSince1970,
        ]
        if let target = goal.targetPosts { out["targetPosts"] = target }
        if let due = goal.dueDate { out["dueDate"] = due.timeIntervalSince1970 }
        return out
    }

    private static func postJSON(_ post: PromotionPost) -> [String: Any] {
        var out: [String: Any] = [
            "id": post.id.uuidString, "platform": post.platform, "title": post.title,
            "status": post.status.rawValue, "createdAt": post.createdAt.timeIntervalSince1970,
            // body 进 JSON（v0.7.18）：选题/草稿的正文（切入角度 + 来源链接）在
            // 这里——桥端集成与 E2E 断言需要；面板读 store、不受影响。
            "body": post.body,
        ]
        if let goalID = post.goalID { out["goalID"] = goalID.uuidString }
        if let url = post.url { out["url"] = url }
        if let published = post.publishedAt { out["publishedAt"] = published.timeIntervalSince1970 }
        if let planned = post.plannedFor { out["plannedFor"] = planned.timeIntervalSince1970 }
        if let m = post.metrics {
            var metrics: [String: Any] = [:]
            if let v = m.views { metrics["views"] = v }
            if let l = m.likes { metrics["likes"] = l }
            if let c = m.comments { metrics["comments"] = c }
            if let at = m.collectedAt { metrics["collectedAt"] = at.timeIntervalSince1970 }
            out["metrics"] = metrics
        }
        if !post.metricHistory.isEmpty {
            out["metricHistory"] = post.metricHistory.map { snapshot -> [String: Any] in
                var row: [String: Any] = ["at": snapshot.at.timeIntervalSince1970]
                if let v = snapshot.views { row["views"] = v }
                if let l = snapshot.likes { row["likes"] = l }
                if let c = snapshot.comments { row["comments"] = c }
                return row
            }
        }
        if let growth = post.viewsGrowth { out["viewsGrowth"] = growth }
        return out
    }

    /// dueDate 接受 ISO8601（"2026-11-01T00:00:00Z"）或 "yyyy-MM-dd"。
    private static func promotionDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: raw) { return d }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: raw)
    }

    /// 广告候选（给 AI 识别广告用）：跑同一份 `ad-candidates.js`，
    /// 面板/工具都没有额外逻辑，桥拿到的就是模型拿到的东西。
    private static func adCandidates(index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        let script = UserScriptLoader.load("ad-candidates")
        guard !script.isEmpty else { return ["error": "ad-candidates script missing"] }
        do {
            let raw = try await tab.browser.webView.callAsyncJavaScript(
                script,
                arguments: ["maxItems": 25],
                in: nil,
                contentWorld: .page
            ) as? String
            guard let raw, let data = raw.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ["error": "could not read candidates"]
            }
            return payload
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// 批量屏蔽元素（与 `blockElements` 工具同一条路径）：写 ElementBlockStore
    /// 规则 + 立刻把隐藏 CSS 注进当前页面；`requests` 额外加网络拦截规则。
    private static func adBlock(selectors: [String], urlPattern: String?, requests: [String], index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard !selectors.isEmpty else { return ["error": "selectors required"] }
        let host = tab.browser.webView.url?.host ?? ""
        let pattern = (urlPattern?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? urlPattern! : (host.isEmpty ? "*" : host))
        var applied: [String] = []
        for selector in selectors.prefix(40) {
            let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !app.elementBlockStore.rules.contains(where: { $0.cssSelector == trimmed && $0.urlPattern == pattern }) else { continue }
            app.elementBlockStore.add(cssSelector: trimmed, urlPattern: pattern)
            applied.append(trimmed)
        }
        if !applied.isEmpty {
            let css = applied.map { "\($0) { display: none !important; }" }.joined()
            let escaped = css
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: " ")
            _ = try? await tab.browser.webView.callAsyncJavaScript("""
            (function() {
                var style = document.getElementById('desire-blocked-selectors') || document.createElement('style');
                style.id = 'desire-blocked-selectors';
                style.textContent = (style.textContent || '') + '\(escaped)';
                if (!style.parentNode) document.head.appendChild(style);
                return 'ok';
            })();
            """, arguments: [:], in: nil, contentWorld: .page)
        }
        var blocked: [String] = []
        for filter in requests.prefix(20) where !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            InterceptStore.shared.add(urlFilter: filter, kind: .block, payload: nil)
            blocked.append(filter)
        }
        return [
            "ok": true,
            "applied": applied,
            "urlPattern": pattern,
            "blockedRequests": blocked,
            "rulesTotal": app.elementBlockStore.rules.count,
        ]
    }

    /// 社区过滤列表（EasyList / EasyList China）的状态：开关、上次更新时间、
    /// 规则数、以及**失败原因**（面板上那句"更新失败"背后的原始错误）。
    private static func filterLists() -> [String: Any] {
        let store = FilterListStore.shared
        return [
            "lists": store.lists.map { list -> [String: Any] in
                var row: [String: Any] = [
                    "id": list.id,
                    "name": list.name,
                    "enabled": list.isEnabled,
                    "updating": list.isUpdating,
                    "source": list.sourceURL.absoluteString,
                ]
                if let last = list.lastUpdated { row["lastUpdated"] = ISO.string(from: last) }
                if let count = list.ruleCount { row["ruleCount"] = count }
                if let error = list.errorText { row["error"] = error }
                return row
            },
        ]
    }

    /// 直接编译若干条 url-filter 正则（隔离试验用：到底哪种构造 WebKit 不收）。
    private static func filterProbeRegexes(_ regexes: [String]) async -> [String: Any] {
        guard let store = WKContentRuleListStore.default() else { return ["error": "no store"] }
        var results: [[String: Any]] = []
        for (index, regex) in regexes.enumerated() {
            let rule: [[String: Any]] = [["trigger": ["url-filter": regex], "action": ["type": "block"]]]
            guard let data = try? JSONSerialization.data(withJSONObject: rule),
                  let json = String(data: data, encoding: .utf8) else { continue }
            let identifier = "probe-r-\(index)-" + UUID().uuidString.prefix(6)
            var row: [String: Any] = ["regex": regex]
            do {
                _ = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
                row["ok"] = true
            } catch {
                row["ok"] = false
                row["error"] = ((error as NSError).userInfo["NSHelpAnchor"] as? String) ?? error.localizedDescription
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
            }
            results.append(row)
        }
        return ["results": results]
    }

    /// 把若干条 ABP 规则转成 content-blocker JSON 并真的交给 WebKit 编译，
    /// 回report 每条的结果与错误。用来定位"哪条规则让整份列表编译失败"。
    private static func filterProbe(abp: String, includeHiding: Bool) async -> [String: Any] {
        let lines = abp.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return ["error": "abp required"] }
        guard let store = WKContentRuleListStore.default() else { return ["error": "no store"] }
        var results: [[String: Any]] = []
        for (index, line) in lines.enumerated() {
            let converted = ABPRuleConverter.convert(line, includeHiding: includeHiding)
            var row: [String: Any] = ["line": line, "rules": converted.ruleCount, "json": String(converted.json.prefix(300))]
            let identifier = "probe-\(index)-" + UUID().uuidString.prefix(6)
            do {
                _ = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: converted.json)
                row["ok"] = true
            } catch {
                row["ok"] = false
                row["error"] = ((error as NSError).userInfo["NSHelpAnchor"] as? String) ?? error.localizedDescription
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
            }
            results.append(row)
        }
        return ["results": results]
    }

    private static func filterListsRefresh(id: String?, force: Bool) -> [String: Any] {
        let store = FilterListStore.shared
        let targets = id.map { [$0] } ?? store.lists.map(\.id)
        for target in targets {
            store.refresh(id: target, force: force)
        }
        return ["ok": true, "refreshed": targets]
    }

    /// 后台媒体导出（downloadMedia）的任务列表与取消。
    private static func mediaExports() -> [String: Any] {
        let jobs = MediaExportStore.shared.jobs
        return [
            "active": MediaExportStore.shared.activeCount,
            "jobs": jobs.suffix(20).map { job -> [String: Any] in
                var row: [String: Any] = [
                    "id": job.id.uuidString,
                    "title": job.title,
                    "state": job.state.rawValue,
                    "url": job.url.absoluteString,
                    "startedAt": ISO.string(from: job.startedAt),
                ]
                if let summary = job.summary { row["summary"] = summary }
                if let finished = job.finishedAt { row["finishedAt"] = ISO.string(from: finished) }
                return row
            },
        ]
    }

    private static func mediaExportCancel(id: String) -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { return ["error": "bad id"] }
        MediaExportStore.shared.cancel(id: uuid)
        return ["ok": true]
    }

    // MARK: 批量视频下载（BatchMediaExportStore）

    /// 启动批量下载。mode=page：当前（或 index 指定）标签页嗅探到的媒体
    /// 全部入队；mode=list：`urls` 里的详情页逐个交给隐藏解析器。
    private static func startMediaBatch(body: [String: Any]) throws -> [String: Any] {
        let mode = Self.string(body, "mode") ?? "page"
        let folderName = Self.string(body, "folderName")
        let naming = Self.string(body, "naming")
        let force = body["force"] as? Bool ?? false
        let directory = Self.string(body, "directory")
        let index = body["index"] as? Int
        switch mode {
        case "page":
            guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
            let media = tab.browser.detectedMedia
            guard !media.isEmpty else {
                return ["error": "no media sniffed on that tab (play the videos once, or use mode=list)"]
            }
            let batch = BatchMediaExportStore.shared.startPageBatch(
                candidates: media.map { ($0.url, $0.kind.rawValue, $0.mime, $0.isBlob) },
                referer: tab.browser.webView.url,
                userAgent: tab.browser.webView.customUserAgent,
                folderName: folderName,
                naming: naming,
                force: force,
                directory: directory,
                splitEvery: (body["splitEvery"] as? Int)
            )
            return ["ok": true, "batchId": batch.id.uuidString, "folder": batch.folderName,
                    "queued": batch.items.filter { $0.state == .pending }.count,
                    "skipped": batch.items.filter { $0.state == .skipped }.count]
        case "list":
            let urls = (body["urls"] as? [String]) ?? []
            guard !urls.isEmpty else { return ["error": "missing urls"] }
            guard urls.count <= BatchMediaExportStore.maxItemsPerBatch else {
                return ["error": "too many urls (cap \(BatchMediaExportStore.maxItemsPerBatch))"]
            }
            // host 垫层只给默认流：显式 directory = 根目录直落，不嵌套
            // （与工具层 downloadVideoList 同一规矩）。
            let trimmedDir = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasDirectory = trimmedDir != nil && !(trimmedDir!.isEmpty) && trimmedDir! != "/"
            let hostFallback: String? = (folderName?.isEmpty == false)
                ? folderName
                : (hasDirectory ? nil : URL(string: urls[0])?.host)
            let batch = BatchMediaExportStore.shared.startListBatch(
                pageURLs: urls,
                userAgent: nil,
                folderName: hostFallback,
                naming: naming,
                force: force,
                directory: directory,
                splitEvery: (body["splitEvery"] as? Int)
            )
            return ["ok": true, "batchId": batch.id.uuidString, "folder": batch.folderName,
                    "queued": batch.items.filter { $0.state == .pending }.count,
                    "skipped": batch.items.filter { $0.state == .skipped }.count]
        default:
            return ["error": "mode must be page or list"]
        }
    }

    /// 本应用在屏窗口清单。`number` 可直接喂给 `screencapture -l<number>`，
    /// 替代此前"swift 脚本查 CGWindowList"的 shell 往返。
    private static func windowsList() -> [String: Any] {
        let windows = NSApp.windows.compactMap { window -> [String: Any]? in
            guard window.isVisible else { return nil }
            let frame = window.frame
            return [
                "number": window.windowNumber,
                "title": window.title,
                "frame": [
                    "x": frame.origin.x, "y": frame.origin.y,
                    "w": frame.width, "h": frame.height,
                ] as [String: Double],
                "isKey": window.isKeyWindow,
                "isFullScreen": window.styleMask.contains(.fullScreen),
            ]
        }
        return ["count": windows.count, "windows": windows]
    }

    /// 会话清单（最新在前）：测试后清理的配套——id/title/首条摘要直接给，
    /// 不用再翻盘上文件。配合 POST /conversations/delete 使用。
    private static func conversationsList(limit: Int) -> [String: Any] {
        let store = AppState.live?.conversationStore ?? ConversationStore()
        let rows = store.conversations.prefix(max(1, limit)).map { conv -> [String: Any] in
            let first = conv.messages.first(where: { $0.role == .user })?.content ?? ""
            return [
                "id": conv.id.uuidString,
                "title": conv.title,
                "updatedAt": ISO.string(from: conv.updatedAt),
                "messages": conv.messages.count,
                "firstMessage": String(first.prefix(80)),
            ]
        }
        return ["count": rows.count, "conversations": Array(rows)]
    }

    private static func logTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// 批次管理（桥直达，不再必须经智能体工具）：pause/resume/cancel/skip。
    /// batchId 支持 8 位短前缀（与 listBatchDownloads 展示一致）。
    private static func batchManage(body: [String: Any]) -> [String: Any] {
        let store = BatchMediaExportStore.shared
        guard let rawID = Self.string(body, "batchId"), !rawID.isEmpty else {
            return ["error": "missing batchId (see GET /media/batch)"]
        }
        let lowered = rawID.lowercased()
        let hits = store.batches.filter {
            $0.id.uuidString == rawID || $0.id.uuidString.lowercased().hasPrefix(lowered)
        }
        guard hits.count == 1, let batch = hits.first else {
            return ["error": hits.isEmpty
                ? "no batch matches '\(rawID)'"
                : "'\(rawID)' matches \(hits.count) batches — use a longer prefix"]
        }
        let batchID = batch.id
        guard let action = Self.string(body, "action")?.lowercased() else {
            return ["error": "missing action (pause/resume/cancel/skip/remove)"]
        }
        switch action {
        case "pause":
            store.pause(batchID: batchID)
            return ["ok": true, "action": "paused", "batch": batchID.uuidString]
        case "resume":
            store.resume(batchID: batchID)
            return ["ok": true, "action": "resumed", "batch": batchID.uuidString]
        case "cancel":
            store.cancel(batchID: batchID)
            return ["ok": true, "action": "cancelled", "batch": batchID.uuidString]
        case "remove":
            // 仅已结束批次：从面板列表移除（running 先 cancel）。
            store.removeSettled(batchID: batchID)
            return ["ok": true, "action": "removed", "batch": batchID.uuidString]
        case "add":
            // 追加任务的**最新参数同步进批次**（并发/分卷）——否则旧批次
            // 的遗留参数（并发 1、分卷 2）绑架后续 12 部，模型只能逐项
            // skip + 重建队列（用户实测的"骚操作"链）。
            if let mc = body["maxConcurrent"] as? Int, (1...4).contains(mc) {
                BatchMediaPreferences.maxConcurrent = mc
            }
            if let se = body["splitEvery"] as? Int {
                store.setSplitEvery(batchID: batchID, se)
            }
            guard let urls = body["urls"] as? [String], !urls.isEmpty else {
                return ["error": "add needs urls (array)"]
            }
            let result = store.addItems(
                batchID: batchID,
                pageURLs: batch.mode == .list ? urls : [],
                mediaURLs: batch.mode == .page ? urls : [],
                referer: nil
            )
            return ["ok": true, "added": result.added, "duplicates": result.duplicates,
                    "maxConcurrent": BatchMediaPreferences.maxConcurrent,
                    "splitEvery": batch.splitEvery ?? 0]
        case "skip":
            guard let rawItem = Self.string(body, "itemId") else {
                return ["error": "skip needs itemId (from GET /media/batch items)"]
            }
            let itemHits = batch.items.filter {
                $0.id.uuidString == rawItem || $0.id.uuidString.lowercased().hasPrefix(rawItem.lowercased())
            }
            guard itemHits.count == 1, let item = itemHits.first else {
                return ["error": itemHits.isEmpty
                    ? "no item matches '\(rawItem)'"
                    : "'\(rawItem)' matches \(itemHits.count) items — use a longer prefix"]
            }
            store.skip(batchID: batchID, itemID: item.id)
            return ["ok": true, "action": "skipped", "item": item.id.uuidString]
        default:
            return ["error": "unknown action '\(action)' (pause/resume/cancel/skip/remove)"]
        }
    }

    /// 批次快照（全部或按 id）：批次级聚合（各状态计数、暂停/挂起态）+
    /// 逐项进度（done/total/单位）。
    private static func batchMediaSnapshot(id: String?) throws -> [String: Any] {
        let store = BatchMediaExportStore.shared
        var batches = store.batches
        if let id, let uuid = UUID(uuidString: id) {
            batches = batches.filter { $0.id == uuid }
        }
        return ["batches": batches.map { batch -> [String: Any] in
            var counts: [String: Int] = [:]
            for item in batch.items { counts[item.state.rawValue, default: 0] += 1 }
            // 落点按批次真实 saveRoot 拼接（folder 空 = 目录直存）。
            let dest = batch.saveRoot ?? (BatchMediaPreferences.baseDirectory ?? NSHomeDirectory() + "/Downloads")
            let leaf = batch.folderName.isEmpty ? "" : "/" + batch.folderName
            var row: [String: Any] = [
                "id": batch.id.uuidString,
                "mode": batch.mode.rawValue,
                "state": batch.state.rawValue,
                "folder": batch.folderName,
                "destination": dest + leaf,
                "finished": batch.finishedCount,
                "total": batch.items.count,
                "counts": counts,
                "createdAt": ISO.string(from: batch.createdAt),
                "paused": store.isPaused(batch.id),
            ]
            if let split = batch.splitEvery, split > 0 { row["splitEvery"] = split }
            if let reason = store.suspensionReason(batch.id) { row["suspended"] = reason }
            row["items"] = batch.items.map { item -> [String: Any] in
                var itemRow: [String: Any] = [
                    "id": item.id.uuidString,
                    "state": item.state.rawValue,
                    "source": item.sourceURL.absoluteString,
                    "attempts": item.attempts,
                ]
                if let media = item.mediaURL { itemRow["media"] = media.absoluteString }
                if !item.title.isEmpty { itemRow["title"] = item.title }
                if let summary = item.summary { itemRow["summary"] = summary }
                if let progress = store.progress(for: item.id) {
                    itemRow["progress"] = [
                        "done": progress.done,
                        "total": progress.total,
                        "unit": progress.unit.rawValue,
                    ]
                }
                return itemRow
            }
            return row
        }]
    }

    /// 手动暂停 / 恢复整批。
    private static func batchMediaPause(id: String, paused: Bool) -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { return ["error": "bad id"] }
        if paused {
            BatchMediaExportStore.shared.pause(batchID: uuid)
        } else {
            BatchMediaExportStore.shared.resume(batchID: uuid)
        }
        return ["ok": true]
    }

    /// 向既有批次追加任务。kind=list（默认）→ urls 是详情页；kind=media →
    /// urls 是媒体地址（仅 page 模式批次）。返回实际追加数与重复数。
    private static func batchMediaAdd(id: String, urls: [String], kind: String, referer: String?) -> [String: Any] {
        guard let uuid = UUID(uuidString: id), !urls.isEmpty else { return ["error": "bad id or missing urls"] }
        guard urls.count <= BatchMediaExportStore.maxItemsPerBatch else {
            return ["error": "too many urls (cap \(BatchMediaExportStore.maxItemsPerBatch))"]
        }
        let refererURL = referer.flatMap { URL(string: $0) }
        let result = BatchMediaExportStore.shared.addItems(
            batchID: uuid,
            pageURLs: kind == "list" ? urls : [],
            mediaURLs: kind == "media" ? urls : [],
            referer: refererURL
        )
        return ["ok": true, "added": result.added, "duplicates": result.duplicates]
    }

    /// 已下载历史（索引的只读视图，最新在前）——供 Agent/外部回答
    /// "之前下过什么"。
    private static func downloadHistory() -> [String: Any] {
        let entries = BatchDownloadedIndex.snapshot()
            .sorted { $0.value.at > $1.value.at }
            .prefix(200)
        return ["history": entries.map { url, entry -> [String: Any] in
            ["url": url, "file": entry.file, "at": ISO.string(from: entry.at)]
        }]
    }

    /// 广告拦截统计（与面板同源 AdBlockStatsStore）。
    private static func adBlockStats() -> [String: Any] {
        let stats = AdBlockStatsStore.shared
        return [
            "total": stats.total,
            "today": stats.todayCount,
            "perDomain": stats.perDomain,
            "recent": stats.recent.prefix(20).map { event in
                [
                    "at": event.at.timeIntervalSince1970,
                    "site": event.site,
                    "count": event.count,
                    "action": event.action,
                ] as [String: Any]
            },
        ]
    }

    /// 批量下载的人性化配置（预留空间 / 命名 / 保存位置）。
    private static func batchMediaConfig() -> [String: Any] {
        [
            "reserveGB": BatchMediaPreferences.reserveGB,
            "naming": BatchMediaPreferences.namingStyle.rawValue,
            "baseDirectory": BatchMediaPreferences.baseDirectory ?? NSNull(),
            "saveRoot": BatchMediaPreferences.baseDirectory ?? "~/Downloads",
            "skipDownloaded": BatchMediaPreferences.skipDownloaded,
            "maxConcurrent": BatchMediaPreferences.maxConcurrent,
            "splitEvery": BatchMediaPreferences.splitEvery ?? 0,
            "exportTimeoutMinutes": BatchMediaPreferences.exportTimeoutMinutes,
        ]
    }

    private static func setBatchMediaConfig(body: [String: Any]) -> [String: Any] {
        if let reserve = body["reserveGB"] as? Int {
            BatchMediaPreferences.reserveGB = reserve
        }
        if let split = body["splitEvery"] as? Int {
            BatchMediaPreferences.splitEvery = split > 0 ? split : nil
        }
        if let timeout = body["exportTimeoutMinutes"] as? Int {
            BatchMediaPreferences.exportTimeoutMinutes = timeout
        }
        if let naming = Self.string(body, "naming"),
           let style = BatchMediaPlan.NamingStyle(rawValue: naming.lowercased()) {
            BatchMediaPreferences.namingStyle = style
        }
        if body["baseDirectory"] is NSNull {
            BatchMediaPreferences.baseDirectory = nil
        } else if let base = Self.string(body, "baseDirectory") {
            guard base.hasPrefix("/") else { return ["error": "baseDirectory must be an absolute path"] }
            BatchMediaPreferences.baseDirectory = base
        }
        if let skip = body["skipDownloaded"] as? Bool {
            BatchMediaPreferences.skipDownloaded = skip
        }
        if let concurrent = body["maxConcurrent"] as? Int {
            BatchMediaPreferences.maxConcurrent = concurrent
        }
        return batchMediaConfig()
    }

    private static func batchMediaCancel(id: String) -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { return ["error": "bad id"] }
        BatchMediaExportStore.shared.cancel(batchID: uuid)
        return ["ok": true]
    }

    private static func batchMediaSkip(id: String, itemID: String) -> [String: Any] {
        guard let uuid = UUID(uuidString: id), let itemUUID = UUID(uuidString: itemID) else {
            return ["error": "bad id"]
        }
        BatchMediaExportStore.shared.skip(batchID: uuid, itemID: itemUUID)
        return ["ok": true]
    }

    private static func batchMediaRetry(id: String) -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { return ["error": "bad id"] }
        BatchMediaExportStore.shared.retryFailed(uuid)
        return ["ok": true]
    }

    /// 往会话追加一条 system 备注（后台任务完成等）。面板不渲染 system 消息，
    /// 但下一轮请求会把它并进开头的 system 提示（**不能留在对话中间**：OpenAI
    /// 兼容服务要求 system 只能在开头）。
    private static func agentNote(text: String, window: String?) throws -> [String: Any] {
        guard !text.isEmpty else { return ["error": "missing text"] }
        guard let session = resolveSession(window) else { return ["error": "no live agent session"] }
        session.appendExternalNote(text)
        return ["ok": true]
    }

    /// 当前挂起的提问（agent askUser / 批量下载低空间询问共用一个通道）。
    private static func pendingPrompt() -> [String: Any] {
        guard let pending = UserPromptCenter.shared.pending else {
            return ["pending": false]
        }
        return [
            "pending": true,
            "id": pending.id.uuidString,
            "question": pending.question,
        ]
    }

    /// 回答挂起的提问（引擎的磁盘询问经这里驱动；answer 幂等保护在
    /// PendingUserQuestion.resume 内部）。
    private static func answerPendingPrompt(text: String) -> [String: Any] {
        guard UserPromptCenter.shared.pending != nil else { return ["error": "no pending prompt"] }
        UserPromptCenter.shared.answer(text)
        return ["ok": true]
    }

    /// 停掉正在跑的一轮（等价于面板里的 Esc / Stop）。
    private static func agentCancel(window: String?) throws -> [String: Any] {        guard let session = resolveSession(window) else {
            return ["error": "no live agent session"]
        }
        let wasBusy = session.isProcessing
        session.cancel()
        return ["ok": true, "wasBusy": wasBusy, "window": window ?? "newest"]
    }

    private static func agentSend(_ text: String?, window: String?, recordHistory: Bool = false) throws -> [String: Any] {
        guard let text, !text.isEmpty else { return ["error": "missing text"] }
        guard let session = resolveSession(window) else {
            return ["error": "no live agent session"]
        }
        session.sendMessage(text, recordHistory: recordHistory)
        return ["ok": true, "window": window ?? "newest"]
    }

    // MARK: Scheduled agent tasks

    private static func agentTasks() throws -> [String: Any] {
        let tasks = AgentScheduler.shared.tasks.map { t -> [String: Any] in
            ["name": t.name, "prompt": t.prompt, "enabled": t.isEnabled,
             "recurrence": t.recurrenceText, "lastResult": t.lastResult ?? ""]
        }
        return ["tasks": tasks]
    }

    private static func createAgentTask(name: String, prompt: String, minutes: Int?, hour: Int?, minute: Int?, window: String?, builtin: String? = nil) throws -> [String: Any] {
        let recurrence: AgentScheduler.ScheduledTask.Recurrence
        if let minutes {
            recurrence = .everyMinutes(minutes)
        } else if let hour, let minute {
            recurrence = .daily(hour: hour, minute: minute)
        } else {
            return ["error": "need minutes, or hour+minute"]
        }
        if let builtin {
            // 内置流水线任务（v0.7.24 起；v0.7.25 泛化）：weeklyReport | dailyBrief。
            guard ["weeklyReport", "dailyBrief"].contains(builtin) else {
                return ["error": "unknown builtin: \(builtin)"]
            }
            let targetID = resolveSession(window)?.registryID
            guard AgentScheduler.shared.addBuiltin(
                name: name, recurrence: recurrence, kind: builtin,
                targetSessionID: targetID) != nil else {
                return ["error": "invalid name"]
            }
            var payload: [String: Any] = ["ok": true, "name": name, "builtin": builtin]
            if let targetID { payload["target"] = targetID.uuidString }
            return payload
        }
        // 多窗口联动：window = 调度器注册 id（见 GET /agent/windows）；缺省 =
        // 跟随最新注册的活会话。
        let targetID = resolveSession(window)?.registryID
        guard AgentScheduler.shared.add(
            name: name, prompt: prompt, recurrence: recurrence,
            targetSessionID: targetID) != nil else {
            return ["error": "invalid name or prompt"]
        }
        var payload: [String: Any] = ["ok": true, "name": name]
        if let targetID { payload["target"] = targetID.uuidString }
        return payload
    }

    private static func removeAgentTask(name: String) throws -> [String: Any] {
        guard AgentScheduler.shared.remove(named: name) else {
            return ["error": "no such task"]
        }
        return ["ok": true]
    }

    private static func fireAgentTask(name: String) throws -> [String: Any] {
        guard AgentScheduler.shared.fireNow(named: name) else {
            return ["error": "no such task"]
        }
        return ["ok": true]
    }

    // MARK: Media

    /// Sniffed/on-page media resources of a tab (listPageVideos' data).
    private static func detectedMedia(index: Int?) throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        return ["media": tab.browser.detectedMedia.map { m -> [String: Any] in
            ["url": m.url, "kind": m.kind, "mime": m.mime, "source": m.source]
        }]
    }

    /// Kicks off a MediaExporter download WITHOUT blocking the caller —
    /// results land in ~/Downloads and the downloads flow. MCP clients must
    /// not hang for 30-minute HLS exports.
    private static func mediaVariants(url: String, referer: String?) async throws -> [String: Any] {
        guard let sourceURL = URL(string: url), !url.isEmpty else { return ["error": "bad url"] }
        let ref = referer.flatMap { URL(string: $0) }
        let variants = try await MediaExporter.listVariants(url: sourceURL, referer: ref, userAgent: nil)
        return ["variants": variants]
    }

    private static func downloadMedia(url: String, referer: String?, fileNameHint: String?, maxBandwidth: Int?) throws -> [String: Any] {
        guard !url.isEmpty, let sourceURL = URL(string: url) else {
            return ["error": "missing or invalid url"]
        }
        let refererURL = referer.flatMap { URL(string: $0) }
        // 走 MediaExportStore（与 agent 工具同路径）：面板可见、/media/exports
        // 可查完成回执（verified 分辨率/音轨 + 源变体清单）。此前裸调
        // MediaExporter.download，回执只进日志、任务在任何列表里都不存在。
        let id = MainActor.assumeIsolated {
            MediaExportStore.shared.start(
                url: sourceURL, referer: refererURL, userAgent: nil,
                fileNameHint: fileNameHint, maxBandwidth: maxBandwidth, notify: false)
        }
        Log.agent.info("media download started: \(url, privacy: .public) job=\(id.uuidString, privacy: .public)")
        return ["ok": true, "started": url, "id": id.uuidString]
    }

    private static func batchDownload(urls: [String]) throws -> [String: Any] {
        guard let store = DownloadStore.live else { return ["error": "store not ready"] }
        var started = 0
        for url in urls {
            guard !url.isEmpty, let sourceURL = URL(string: url) else { continue }
            let filename = sourceURL.lastPathComponent.isEmpty ? "download" : sourceURL.lastPathComponent
            store.startURLSessionDownload(sourceURL: sourceURL, filename: filename)
            started += 1
        }
        return ["ok": true, "started": started]
    }

    private static func startDownload(url: String) throws -> [String: Any] {
        guard let store = DownloadStore.live, !url.isEmpty,
              let sourceURL = URL(string: url) else { return ["error": "bad url"] }
        let filename = sourceURL.lastPathComponent.isEmpty ? "download" : sourceURL.lastPathComponent
        store.startURLSessionDownload(sourceURL: sourceURL, filename: filename)
        return ["ok": true]
    }


    private func setActiveProfile(name: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let tm = try tabManager else { return ["error": "no tab manager"] }
        if name.isEmpty || name.lowercased() == "default" {
            tm.profileDataStore = nil
            app.applyProfile(nil)
            return ["ok": true, "profile": "default"]
        }
        guard let profile = ProfileStore.shared.profile(named: name) else {
            return ["error": "no such profile"]
        }
        tm.profileDataStore = ProfileStore.shared.dataStore(for: profile.id)
        app.applyProfile(profile.id)
        return ["ok": true, "profile": profile.name]
    }

    // MARK: Profiles (0.2.9)

    private static func profiles() throws -> [String: Any] {
        let store = ProfileStore.shared
        return ["profiles": store.profiles.map { p -> [String: Any] in
            ["id": p.id.uuidString, "name": p.name, "color": p.colorName]
        }]
    }

    private static func addProfile(name: String) throws -> [String: Any] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["error": "missing name"] }
        let profile = ProfileStore.shared.addProfile(name: trimmed)
        return ["ok": true, "id": profile.id.uuidString, "name": profile.name]
    }

    private static func removeProfile(name: String) throws -> [String: Any] {
        guard let profile = ProfileStore.shared.profile(named: name) else {
            return ["error": "no such profile"]
        }
        ProfileStore.shared.removeProfile(id: profile.id)
        return ["ok": true]
    }

    // MARK: Page watches

    private static func listWatches() throws -> [String: Any] {
        let store = PageWatchStore.shared
        let iso = ISO8601DateFormatter()
        return ["watches": store.watches.map { w -> [String: Any] in
            var row: [String: Any] = [
                "name": w.name, "url": w.url, "selector": w.selector ?? "",
                "minutes": w.intervalMinutes, "enabled": w.isEnabled,
                "changeCount": w.changeCount, "lastError": w.lastError ?? "",
                "aiAnalysis": w.wantsAIAnalysis, "lastAnalysis": w.lastAnalysis ?? "",
            ]
            if let numericSelector = w.numericSelector {
                row["numericSelector"] = numericSelector
                row["valueCount"] = w.valueHistory?.count ?? 0
                if let latest = w.latestValue { row["latestValue"] = latest }
                if let above = w.alertAbove { row["alertAbove"] = above }
                if let below = w.alertBelow { row["alertBelow"] = below }
                if let alert = w.lastAlert { row["lastAlert"] = alert }
                if let at = w.lastAlertAt { row["lastAlertAt"] = iso.string(from: at) }
            }
            return row
        }]
    }

    private static func addWatch(name: String, url: String, selector: String?, minutes: Int, aiAnalysis: Bool?,
                                 numericSelector: String? = nil, alertAbove: Double? = nil,
                                 alertBelow: Double? = nil) throws -> [String: Any] {
        guard PageWatchStore.shared.add(name: name, url: url, selector: selector, minutes: minutes,
                                        aiAnalysis: aiAnalysis ?? false,
                                        numericSelector: numericSelector,
                                        alertAbove: alertAbove,
                                        alertBelow: alertBelow) != nil else {
            return ["error": "invalid name/url"]
        }
        return ["ok": true, "name": name]
    }

    private static func removeWatch(name: String) throws -> [String: Any] {
        guard PageWatchStore.shared.remove(named: name) else { return ["error": "no such watch"] }
        return ["ok": true]
    }

    private static func setWatchEnabled(name: String, enabled: Bool?) throws -> [String: Any] {
        guard let watch = PageWatchStore.shared.find(named: name) else { return ["error": "no such watch"] }
        PageWatchStore.shared.setEnabled(enabled ?? !watch.isEnabled, for: name)
        return ["ok": true, "enabled": enabled ?? !watch.isEnabled]
    }

    /// Forces a watch check now (async — loads the page offscreen).
    private static func checkWatch(name: String) async throws -> [String: Any] {
        guard PageWatchStore.shared.find(named: name) != nil else {
            return ["error": "no such watch"]
        }
        let changed = await PageWatchStore.shared.check(named: name)
        var result: [String: Any] = ["ok": true, "name": name, "changed": changed]
        if let updated = PageWatchStore.shared.find(named: name) {
            if let latest = updated.latestValue { result["latestValue"] = latest }
            if let alert = updated.lastAlert { result["lastAlert"] = alert }
            if let err = updated.lastError { result["lastError"] = err }
        }
        return result
    }

    // MARK: Memory + skills management (0.1.15)

    private static func searchMemory(query: String) throws -> [String: Any] {
        let results = AgentMemoryStore.shared.searchFacts(query: query)
        return ["results": results.map { f -> [String: Any] in
            ["id": f.id.uuidString, "content": f.content, "category": f.category,
             "pinned": f.pinned, "scope": f.scope, "updatedAt": ISO.string(from: f.updatedAt)]
        }]
    }

    /// 端上句向量探针（0.7.1 阶段二链路验证）：单条文本 → 维度/范数/耗时。
    private static func embedProbe(text: String) async -> [String: Any] {
        guard BGEEmbedder.isAvailable else { return ["available": false] }
        guard !text.isEmpty else { return ["available": true, "error": "missing text"] }
        let start = Date()
        let vector = await Task.detached(priority: .userInitiated) {
            BGEEmbedder.embed(text)
        }.value
        let ms = Date().timeIntervalSince(start) * 1000
        guard let vector else { return ["available": true, "embedded": false] }
        return ["available": true, "dim": vector.count, "ms": ms,
                "head": Array(vector.prefix(4))]
    }

    /// 向量检索回归（应用内 30×15 验收集跑法）：body 带
    /// `facts: [{content, category}]` 与 `queries: [{q, expect}]`，
    /// 返回逐查询的 top-5 位次与汇总命中率——与 tools/vector-spike 的
    /// 离线探针同一套对照集、同一决策语义（rankWithVectors）。
    private static func retrievalEval(body: [String: Any]) async -> [String: Any] {
        guard BGEEmbedder.isAvailable else { return ["available": false] }
        let factBody = body["facts"] as? [[String: Any]] ?? []
        let queryBody = body["queries"] as? [[String: Any]] ?? []
        guard !factBody.isEmpty, !queryBody.isEmpty else {
            return ["available": true, "error": "missing facts/queries"]
        }
        let memFacts = factBody.map {
            MemoryFact(content: $0["content"] as? String ?? "",
                       category: $0["category"] as? String ?? "fact")
        }
        let evalQueries: [(String, Int)] = queryBody.compactMap {
            guard let q = $0["q"] as? String else { return nil }
            return (q, $0["expect"] as? Int ?? 0)
        }
        let indexByID = Dictionary(uniqueKeysWithValues:
            memFacts.enumerated().map { ($1.id, $0) })
        let vectors = await Task.detached(priority: .userInitiated) {
            var result: [UUID: [Double]] = [:]
            for fact in memFacts {
                if let v = BGEEmbedder.embedFact(fact.content) {
                    result[fact.id] = v
                }
            }
            return result
        }.value
        var results: [[String: Any]] = []
        var top1 = 0, top3 = 0
        for (q, expect) in evalQueries {
            let queryVector = await Task.detached(priority: .userInitiated) {
                BGEEmbedder.embedQuery(q)
            }.value
            let ranked = MemoryRetrieval.rankWithVectors(
                facts: memFacts, query: q, queryVector: queryVector, vectorsByFactID: vectors)
            let order = ranked.compactMap { indexByID[$0.id] }
            let pos = order.firstIndex(of: expect).map { $0 + 1 } ?? -1
            if pos == 1 { top1 += 1 }
            if pos >= 1 && pos <= 3 { top3 += 1 }
            results.append(["q": q, "expect": expect, "rank": pos,
                            "top5": Array(order.prefix(5))])
        }
        return ["available": true, "total": evalQueries.count, "top1": top1,
                "top3": top3, "results": results]
    }

    private static func exportMemory() throws -> [String: Any] {
        let json = AgentMemoryStore.shared.exportJSON()
        let path = NSHomeDirectory() + "/desire-memory-export.json"
        try json.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        return ["path": path, "bytes": json.count]
    }

    private static func decayMemory(olderThanDays days: Int) throws -> [String: Any] {
        let removed = AgentMemoryStore.shared.decayOldFacts(olderThanDays: days)
        return ["ok": true, "removed": removed]
    }

    private static func memorySnapshot() -> [String: Any] {
        let store = AgentMemoryStore.shared
        return [
            "profile": [
                "name": store.profileSnapshot.name, "language": store.profileSnapshot.language,
                "style": store.profileSnapshot.style, "customInstructions": store.profileSnapshot.customInstructions,
            ],
            "facts": store.factsSnapshot.map { f -> [String: Any] in
                ["id": f.id.uuidString, "content": f.content, "category": f.category,
                 "pinned": f.pinned, "scope": f.scope, "updatedAt": ISO.string(from: f.updatedAt)]
            },
            "summaries": store.summariesCount,
        ]
    }

    private static func addMemoryFact(content: String, category: String, scope: String) throws -> [String: Any] {
        guard !content.isEmpty else { return ["error": "missing content"] }
        AgentMemoryStore.shared.addFact(content: content, category: category, scope: scope)
        return ["ok": true]
    }

    /// 评估集导出（v0.7.22）：👍 回合 → JSONL（复用 AgentTrace 派生）。
    private static func evalExport(path: String?) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let directory = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        do {
            let result = try EvalExporter.export(conversationStore: app.conversationStore,
                                                 price: app.aiPreference.usagePrice(for:),
                                                 to: directory)
            return ["ok": true, "path": result.url.path, "turns": result.count]
        } catch {
            return ["error": "export failed: \(error.localizedDescription)"]
        }
    }

    /// 已有评估集导出（新→旧）。
    private static func evalExportsList() throws -> [String: Any] {
        let exports = EvalExporter.listExports().map { entry in
            ["name": entry.url.lastPathComponent,
             "path": entry.url.path,
             "size": entry.size,
             "modified": entry.modified.timeIntervalSince1970] as [String: Any]
        }
        return ["ok": true, "exports": exports]
    }

    private static func evalExportDelete(path: String) throws -> [String: Any] {
        guard path.hasSuffix(".jsonl"),
              URL(fileURLWithPath: path).lastPathComponent.hasPrefix("eval-thumbsup-") else {
            return ["error": "仅允许删除 eval-thumbsup-*.jsonl"]
        }
        EvalExporter.delete(URL(fileURLWithPath: path))
        return ["ok": true]
    }

    /// 登记为 agent-eval fixtures（v0.7.27）：JSONL → 脱敏 JSON。
    private static func evalFixtureRegister(path: String?) throws -> [String: Any] {
        guard let path, !path.isEmpty else { return ["error": "missing path"] }
        do {
            let result = try EvalExporter.registerAsFixture(from: URL(fileURLWithPath: path))
            return ["ok": true, "path": result.url.path, "count": result.count]
        } catch {
            return ["error": "register failed: \(error.localizedDescription)"]
        }
    }

    /// 已有 fixtures（新→旧）。
    private static func evalFixturesList() throws -> [String: Any] {
        let fixtures = EvalExporter.listFixtures().map { entry in
            ["name": entry.url.lastPathComponent,
             "path": entry.url.path,
             "count": entry.count,
             "modified": entry.modified.timeIntervalSince1970] as [String: Any]
        }
        return ["ok": true, "fixtures": fixtures,
                "directory": EvalExporter.fixturesDirectory.path]
    }

    private static func evalFixtureDelete(path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent.hasPrefix("fixtures-"), url.pathExtension == "json" else {
            return ["error": "仅允许删除 fixtures-*.json"]
        }
        EvalExporter.deleteFixture(url)
        return ["ok": true]
    }

    /// 统一备份（v0.7.28）：path 是文件（.json）或目录（自动取默认文件名）。
    private static func backupExport(body: [String: Any]) throws -> [String: Any] {
        guard let path = Self.string(body, "path"), !path.isEmpty else {
            return ["error": "missing path"]
        }
        let url = URL(fileURLWithPath: path)
        let passphrase = Self.string(body, "passphrase")
        do {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let result: (url: URL, counts: [String: Int])
            if isDirectory || !path.hasSuffix(".json") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                result = try BackupService.export(toDirectory: url, passphrase: passphrase)
            } else {
                result = try BackupService.export(to: url, passphrase: passphrase)
            }
            return ["ok": true, "path": result.url.path, "counts": result.counts]
        } catch {
            return ["error": "export failed: \(error.localizedDescription)"]
        }
    }

    private static func backupImport(body: [String: Any]) throws -> [String: Any] {
        guard let path = Self.string(body, "path"), !path.isEmpty else {
            return ["error": "missing path"]
        }
        let mode = BackupService.Mode(rawValue: Self.string(body, "mode") ?? "merge") ?? .merge
        let domains: Set<BackupArchive.Domain>? = (body["domains"] as? [String]).map { raw in
            Set(raw.compactMap(BackupArchive.Domain.init(rawValue:)))
        }
        do {
            let applied = try BackupService.importArchive(from: URL(fileURLWithPath: path),
                                                          mode: mode,
                                                          domains: domains,
                                                          passphrase: Self.string(body, "passphrase"))
            return ["ok": true, "mode": mode.rawValue, "applied": applied]
        } catch {
            return ["error": "import failed: \(error.localizedDescription)"]
        }
    }

    // MARK: - Workflow recorder/replay（v0.7.29）

    private static func workflowStart() throws -> [String: Any] {
        guard let tm = try shared.tabManager, let tab = tm.selectedTab else {
            return ["error": "no active tab"]
        }
        let url = tab.browser.webView.url?.absoluteString ?? tab.urlString
        guard WorkflowLogic.host(of: url) != nil else {
            return ["error": "the active tab has no site"]
        }
        WorkflowStore.shared.startRecording(url: url)
        tab.browser.webView.evaluateJavaScript("window.__desireWorkflowRecording = true",
                                               completionHandler: nil)
        return ["ok": true, "host": WorkflowStore.shared.recordingHost ?? ""]
    }

    private static func workflowStop(name: String) throws -> [String: Any] {
        guard let tm = try shared.tabManager, let tab = tm.selectedTab else {
            return ["error": "no active tab"]
        }
        tab.browser.webView.evaluateJavaScript("window.__desireWorkflowRecording = false",
                                               completionHandler: nil)
        guard let workflow = WorkflowStore.shared.stopRecording(name: name) else {
            return ["error": "nothing recorded"]
        }
        return workflowSummary(workflow)
    }

    private static func workflowOffer(body: [String: Any]) throws -> [String: Any] {
        let workflows = WorkflowStore.shared.workflows
        var workflow: Workflow?
        if let raw = Self.string(body, "id"), let id = UUID(uuidString: raw) {
            workflow = workflows.first { $0.id == id }
        } else if let name = Self.string(body, "name"), !name.isEmpty {
            workflow = workflows.first { $0.name == name }
        }
        guard let workflow else { return ["error": "workflow not found"] }
        let offer = body["offer"] as? Bool ?? true
        WorkflowStore.shared.setOfferOnVisit(workflow.id, offer)
        return ["ok": true, "id": workflow.id.uuidString, "offer": offer]
    }

    private static func workflowList() throws -> [String: Any] {
        ["ok": true, "workflows": WorkflowStore.shared.workflows.map(workflowSummary)]
    }

    private static func workflowSummary(_ workflow: Workflow) -> [String: Any] {
        ["id": workflow.id.uuidString,
         "name": workflow.name,
         "host": workflow.host,
         "startURL": workflow.startURL,
         "steps": workflow.steps.count,
         "sensitive": workflow.steps.filter(\.sensitive).count,
         "offerOnVisit": workflow.offerOnVisit ?? false,
         "updatedAt": workflow.updatedAt.timeIntervalSince1970,
         "stepDetails": workflow.steps.map { step -> [String: Any] in
             var row: [String: Any] = ["id": step.id.uuidString,
                                       "kind": step.kind.rawValue,
                                       "selectors": step.selectors,
                                       "sensitive": step.sensitive]
             if let value = step.value { row["value"] = value }
             if let url = step.url { row["url"] = url }
             return row
         }]
    }

    private static func workflowRun(body: [String: Any]) async throws -> [String: Any] {
        let workflows = WorkflowStore.shared.workflows
        var workflow: Workflow?
        if let rawID = Self.string(body, "id"), let id = UUID(uuidString: rawID) {
            workflow = workflows.first { $0.id == id }
        } else if let name = Self.string(body, "name"), !name.isEmpty {
            workflow = workflows.first { $0.name == name }
        }
        guard let workflow else { return ["error": "workflow not found"] }
        guard let tm = try shared.tabManager, let tab = tm.selectedTab else {
            return ["error": "no active tab"]
        }
        var values: [UUID: String] = [:]
        if let raw = body["values"] as? [String: Any] {
            for (key, value) in raw {
                if let id = UUID(uuidString: key), let text = value as? String {
                    values[id] = text
                }
            }
        }
        let missing = WorkflowLogic.missingSensitiveValues(workflow, values: values)
        guard missing.isEmpty else {
            return ["error": "missing sensitive values", "missing": missing.map(\.uuidString)]
        }
        let result = await WorkflowPlayer.run(workflow, values: values, in: tab.browser.webView)
        return ["ok": result.ok,
                "results": result.results.map {
                    ["index": $0.index,
                     "kind": $0.kind.rawValue,
                     "ok": $0.ok,
                     "message": $0.message] as [String: Any]
                }]
    }

    private static func workflowDelete(id: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { return ["error": "invalid id"] }
        WorkflowStore.shared.delete(uuid)
        return ["ok": true]
    }

    /// 诊断包（v0.7.28）：MetricKit 报告 + 崩溃计数 + 最近 30 分钟 OSLog。
    private static func diagExport() throws -> [String: Any] {
        guard let url = MetricsManager.shared.exportDiagnosticsArchive() else {
            return ["error": "diagnostics export failed"]
        }
        return ["ok": true, "path": url.path]
    }

    private static func backupPreview(body: [String: Any]) throws -> [String: Any] {        guard let path = Self.string(body, "path"), !path.isEmpty else {
            return ["error": "missing path"]
        }
        do {
            let preview = try BackupService.preview(from: URL(fileURLWithPath: path))
            return ["ok": true,
                    "version": preview.version,
                    "exportedAt": preview.exportedAt.timeIntervalSince1970,
                    "appVersion": preview.appVersion,
                    "counts": preview.counts,
                    "supported": preview.supported,
                    "encrypted": preview.encrypted]
        } catch {
            return ["error": "preview failed: \(error.localizedDescription)"]
        }
    }

    /// Tab Crew 运行观察（面板条子的桥等价；进度字段见 AgentCrewStore.noteProgress）。
    private static func crewState() -> [String: Any] {
        let store = AgentCrewStore.shared
        guard let crew = store.crew else { return ["ok": true, "crew": false] }
        let workers: [[String: Any]] = crew.tasks.map { t in
            var row: [String: Any] = ["index": t.index, "state": t.state.rawValue,
                                      "instruction": t.instruction,
                                      "toolCalls": t.toolCallCount,
                                      "promptTokens": t.promptTokens,
                                      "completionTokens": t.completionTokens]
            if let step = t.currentStep { row["currentStep"] = step }
            if let model = t.model { row["model"] = model }
            if let started = t.startedAt { row["elapsedSec"] = Date().timeIntervalSince(started) }
            if let result = t.result { row["result"] = String(result.prefix(400)) }
            return row
        }
        return ["ok": true, "crew": true,
                "objective": crew.objective,
                "settled": crew.isSettled,
                "doneCount": crew.completedCount,
                "failedCount": crew.failedCount,
                "tokens": store.usage.promptTokens + store.usage.completionTokens,
                "workers": workers]
    }

    /// Crew 控制：clear（落定后清条子）/ cancel（运行中全取消）。
    private static func crewAction(_ action: String) throws -> [String: Any] {
        let store = AgentCrewStore.shared
        switch action {
        case "clear":
            store.clear()
        case "cancel":
            store.cancelAll()
        default:
            return ["error": "action must be clear | cancel"]
        }
        return crewState()
    }

    /// 收件箱批处理（v0.7.22）：忽略（永久隐藏）/ 稍后（定时回列表）。
    private static func inboxDismiss(body: [String: Any]) throws -> [String: Any] {
        let store = AgentInboxDismissalStore.shared
        let ids = ((body["ids"] as? [Any]) ?? []).compactMap { $0 as? String }
        guard !ids.isEmpty else { return ["error": "missing ids"] }
        switch Self.string(body, "action") ?? "ignore" {
        case "ignore":
            store.ignore(ids)
        case "snooze":
            let until: Date
            if let epoch = body["until"] as? Double {
                until = Date(timeIntervalSince1970: epoch)
            } else {
                let hours = max(1, (body["hours"] as? Double) ?? 1)
                until = Date().addingTimeInterval(hours * 3600)
            }
            store.snooze(ids, until: until)
        default:
            return ["error": "action must be ignore | snooze"]
        }
        return ["ok": true, "hiddenCount": store.hiddenCount]
    }

    /// 收件箱批量动作（v0.7.27）：retry = 重跑失败任务（并把旧失败条目稍后
    /// 一小时隐藏，避免重跑期间仍在列表里）；ignore / snooze 与 dismiss 同源。
    private static func inboxBatch(body: [String: Any]) throws -> [String: Any] {
        let ids = ((body["ids"] as? [Any]) ?? []).compactMap { $0 as? String }
        guard !ids.isEmpty else { return ["error": "missing ids"] }
        switch Self.string(body, "action") ?? "retry" {
        case "ignore", "snooze":
            return try inboxDismiss(body: body)
        case "retry":
            var retried: [String] = []
            var skipped: [String] = []
            var retryIDs: [String] = []
            for id in ids {
                guard let name = AgentInbox.taskName(fromItemID: id),
                      AgentScheduler.shared.fireNow(named: name) else {
                    skipped.append(id)
                    continue
                }
                retried.append(name)
                retryIDs.append(id)
            }
            if !retryIDs.isEmpty {
                AgentInboxDismissalStore.shared.snooze(retryIDs,
                                                       until: Date().addingTimeInterval(3600))
            }
            return ["ok": true, "retried": retried, "skipped": skipped,
                    "hiddenCount": AgentInboxDismissalStore.shared.hiddenCount]
        default:
            return ["error": "action must be retry | ignore | snooze"]
        }
    }

    /// 恢复隐藏条目（ids 缺省/null = 全部）。
    private static func inboxRestore(ids: [String]?) throws -> [String: Any] {
        let store = AgentInboxDismissalStore.shared
        let restored = store.restore(ids: ids)
        return ["ok": true, "restored": restored, "hiddenCount": store.hiddenCount]
    }

    /// 会话列表帧（含未读接力字段）——与发给手机的 sessions 帧同构（同一
    /// 构建函数），探针/E2E 断言用。
    private static func remoteSessionsFrame() -> [String: Any] {
        guard let raw = AppState.live?.remoteControlStore.debugSessionsFrame(),
              let data = raw.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["error": "no sessions frame"]
        }
        return dict
    }

    /// 当前会话白板的**快照载荷**（v0.7.23 跨端可读化）：与 RemoteControlStore
    /// 发送的 board 帧同源同构建——探针/两端契约断言用。
    /// 归档历史检索（v0.7.25，桥 = SyncStore 同源）。
    private static func historyArchiveSearch(query: String, limit: Int) async -> [String: Any] {
        guard let store = AppState.live?.syncStore else { return ["error": "app state not ready"] }
        do {
            let hits = try await store.searchArchivedHistory(query: query, limit: limit)
            return ["ok": true, "count": hits.count,
                    "hits": hits.map {
                        ["title": $0.title, "url": $0.url,
                         "timestamp": $0.timestamp.timeIntervalSince1970,
                         "visitCount": $0.visitCount] as [String: Any]
                    }]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// 每日简报（v0.7.25，桥 = 服务同源）。
    private static func dailyBriefRun(toBoard: Bool?) -> [String: Any] {
        let text = DailyBriefService.runNow(toBoard: toBoard)
        return ["ok": true, "text": text, "chars": text.count]
    }

    /// 划词就地卡（v0.7.25，桥 = 服务同源；同一 stream 路径）。
    private static func selectionAssist(text: String, mode: String) async -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["error": "Missing text"] }
        let requested: SelectionAssistMode?
        switch mode {
        case "auto": requested = nil
        case "explain": requested = .explain
        case "translate": requested = .translate
        case "dictionary": requested = .dictionary
        default: return ["error": "mode must be auto | explain | translate | dictionary"]
        }
        let effective = requested ?? SelectionAssistMode.detect(trimmed)
        do {
            let result = try await SelectionAssistService.stream(
                text: trimmed, mode: effective, onDelta: { _ in },
                onUsage: { prompt, completion, model in
                    // 旁路归账（与 UI 卡片同路径）：划词成本并入会话内最近助手消息。
                    AgentScheduler.shared.deliveryTarget?.attributeAssistantBypassUsage(
                        kind: "selectionAssist", prompt: prompt,
                        completion: completion, model: model)
                })
            return ["ok": true, "mode": effective.rawValue, "text": result, "chars": result.count]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// 社区模板列表/导入（v0.7.24，桥 = 服务同源；E2E 用 baseURL 指 fixture）。
    private static func boardGalleryList(base: String?) async -> [String: Any] {
        do {
            let boards = try await BoardGalleryService.fetchIndex(base: base ?? BoardGallery.defaultBaseURL)
            return ["ok": true, "count": boards.count,
                    "boards": boards.map {
                        ["id": $0.id, "name": $0.name, "description": $0.description,
                         "file": $0.file, "blocks": $0.blocks ?? 0] as [String: Any]
                    }]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private static func boardGalleryImport(id: String, mode: String, base: String?,
                                           conversationId: String?) async -> [String: Any] {
        let baseURL = base ?? BoardGallery.defaultBaseURL
        do {
            let boards = try await BoardGalleryService.fetchIndex(base: baseURL)
            guard let board = boards.first(where: { $0.id == id }) else {
                return ["error": "no such template: \(id)"]
            }
            let spec = try await BoardGalleryService.fetchBoard(board, base: baseURL)
            let store = WhiteboardStore.shared
            let conversation = conversationId
                ?? AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
            let current = store.board(for: conversation)
            let effective = mode == "auto" ? (current.blocks.isEmpty ? "replace" : "append") : mode
            switch effective {
            case "replace":
                store.set(WhiteboardSpec(title: spec.title, blocks: spec.blocks), conversationID: conversation)
            case "append":
                store.append(spec.blocks, title: spec.title, conversationID: conversation)
            default:
                return ["error": "mode must be auto | append | replace"]
            }
            let after = store.board(for: conversation)
            return ["ok": true, "id": id, "title": spec.title,
                    "importedBlocks": spec.blocks.count, "boardBlocks": after.blocks.count,
                    "mode": effective]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// 网页分享卡（v0.7.24，桥 = 服务同源）。
    private static func pageShareCard(index: Int?, summarize: Bool) async -> [String: Any] {
        do {
            let outcome = try await PageShareCardService.generate(index: index, summarize: summarize)
            return ["ok": true,
                    "path": outcome.url.path,
                    "title": outcome.title,
                    "domain": outcome.domain,
                    "summaryChars": outcome.summaryChars,
                    "width": outcome.width,
                    "height": outcome.height]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private static func remoteBoardPayload(conversationId: String?) -> [String: Any] {
        let id = conversationId
            ?? AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
        guard let payload = RemoteControlStore.boardPayload(id) else {
            return ["ok": true, "board": false]
        }
        let blocks: [[String: Any]] = payload.blocks.map { block in
            var row: [String: Any] = ["type": block.type,
                                      "preview": block.preview,
                                      "contentLength": block.contentLength]
            if let title = block.title { row["title"] = title }
            if let text = block.text { row["text"] = text }
            if let rows = block.rows { row["rows"] = rows }
            if let thumb = block.imageThumb { row["imageThumb"] = thumb }
            return row
        }
        var out: [String: Any] = ["ok": true, "board": true, "title": payload.title, "blocks": blocks,
                                  "payloadBytes": RemoteBoardContent.encodedSize(payload.blocks)]
        if let comments = payload.comments {
            out["comments"] = comments.map {
                ["text": $0.text, "author": $0.author, "target": $0.target,
                 "resolved": $0.resolved] as [String: Any]
            }
        }
        return out
    }

    /// 同步冲突明细（v0.7.23）：最近本机 LWW 输掉的条目（解密标签）。
    private static func syncConflicts() -> [String: Any] {
        guard let store = AppState.live?.syncStore else { return ["error": "app state not ready"] }
        let notes = store.recentConflicts.map { note in
            ["id": note.id.uuidString, "domain": note.domain,
             "label": note.label, "at": note.at.timeIntervalSince1970] as [String: Any]
        }
        return ["ok": true, "count": notes.count, "conflicts": notes]
    }

    /// 周报状态（面板设置行的桥等价）。
    private static func weeklyDigestState() -> [String: Any] {
        let store = WeeklyDigestStore.shared
        return ["ok": true,
                "enabled": store.isEnabled,
                "weekday": store.weekday,
                "hour": store.hour,
                "due": store.isDue(),
                "lastDeliveredAt": store.lastDeliveredAt?.timeIntervalSince1970 ?? 0,
                "lastText": store.lastDigestText ?? ""]
    }

    /// 周报动作：run-now（立即生成并投递）/ enable / disable。
    private static func weeklyDigestAction(action: String, writeToNotes: Bool = false,
                                           conversationId: String? = nil) async -> [String: Any] {
        let store = WeeklyDigestStore.shared
        switch action {
        case "run-now":
            let text = await store.runNow()
            var state = weeklyDigestState()
            state["text"] = text
            return state
        case "run-pipeline":
            // 报告流水线（v0.7.24）：汇总 → 上板（周报模板）→ 可选备忘录。
            // conversationId 显式指定时只碰那块板（探针用）。
            let outcome = await WeeklyReportPipeline.run(
                days: 7, writeToNotes: writeToNotes, conversationID: conversationId)
            return ["ok": true,
                    "digestChars": outcome.digestChars,
                    "boardBlocks": outcome.boardBlocks,
                    "seededBoard": outcome.seededBoard,
                    "notes": outcome.notes]
        case "enable":
            store.isEnabled = true
        case "disable":
            store.isEnabled = false
        default:
            return ["error": "action must be run-now | run-pipeline | enable | disable"]
        }
        return weeklyDigestState()
    }

    /// 轨迹复盘卡（v0.7.22）：回合的失败/慢模式 → 输出规则草稿（模板化派生，不经模型）。
    private static func agentRuleDraft(conversation: String?, turn: Int?) throws -> [String: Any] {
        guard let store = AppState.live?.conversationStore else { return ["error": "app state not ready"] }
        let conv = conversation.flatMap { UUID(uuidString: $0) }
            .flatMap { store.conversation(for: $0) }
            ?? AgentScheduler.shared.deliveryTarget?.conversationId
                .flatMap { store.conversation(for: $0) }
        guard let conv else { return ["error": "no conversation"] }
        let price = AppState.live?.aiPreference.usagePrice(for:)
        let turns = AgentTrace.turns(of: conv, price: price)
        guard !turns.isEmpty else { return ["error": "no turns"] }
        let index = turn.map { min(max(0, $0), turns.count - 1) } ?? (turns.count - 1)
        let drafts = TurnReview.drafts(from: TurnReview.stepFacts(fromTurn: turns[index]))
        return ["ok": true, "turn": index,
                "drafts": drafts.map { draft in
                    ["kind": draft.kind.rawValue, "tool": draft.tool,
                     "avgMs": draft.avgMs ?? 0] as [String: Any]
                },
                "texts": drafts.map(TurnReview.ruleText(for:))]
    }

    /// 输出规则（<output_rules> 层）的增删查——轨迹复盘卡"一键写进"的桥等价。
    private static func outputRulesList() throws -> [String: Any] {
        ["ok": true, "rules": AppState.live?.aiPreference.outputRules ?? []]
    }

    private static func outputRulesAdd(text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["error": "missing text"] }
        guard let preference = AppState.live?.aiPreference else { return ["error": "app state not ready"] }
        if !preference.outputRules.contains(trimmed) {
            preference.outputRules.append(trimmed)
        }
        return ["ok": true, "rules": preference.outputRules]
    }

    private static func outputRulesRemove(text: String) throws -> [String: Any] {
        guard let preference = AppState.live?.aiPreference else { return ["error": "app state not ready"] }
        preference.outputRules.removeAll { $0 == text }
        return ["ok": true, "rules": preference.outputRules]
    }

    /// 冲突复核队列（近似判定口径；面板横幅的桥等价）。
    private static func memoryConflicts() throws -> [String: Any] {
        let store = AgentMemoryStore.shared
        store.prunePendingConflicts()
        let entries: [[String: Any]] = store.pendingConflicts.map { pending in
            let fact = store.factsSnapshot.first { $0.id == pending.factID }
            let related = pending.relatedIDs.compactMap { id in
                store.factsSnapshot.first { $0.id == id }.map {
                    ["id": $0.id.uuidString, "content": $0.content]
                }
            }
            return ["factID": pending.factID.uuidString,
                    "content": fact?.content ?? "",
                    "related": related]
        }
        return ["ok": true, "count": entries.count, "conflicts": entries]
    }

    /// 复核决议（面板向导的桥等价）：resolution = keepNew|keepOld|keepBoth|merge。
    /// `factID` 给复核态（已入库）；`newText` 给手动态（尚未入库）。
    private static func resolveMemoryConflict(body: [String: Any]) throws -> [String: Any] {
        let store = AgentMemoryStore.shared
        guard let resolutionRaw = Self.string(body, "resolution"),
              let resolution = AgentMemoryStore.ConflictResolution(rawValue: resolutionRaw) else {
            return ["error": "resolution must be keepNew | keepOld | keepBoth | merge"]
        }
        // 逐元素容错：数组里混 null/非字符串时**不能整体退化**为空
        //（`as? [String]` 遇 NSNull 会整组 nil——静默吞参，2026-10-18 探针照出）。
        let relatedIDs = ((body["relatedIDs"] as? [Any]) ?? [])
            .compactMap { $0 as? String }
            .compactMap { UUID(uuidString: $0) }
        let mergedText = Self.string(body, "mergedText")
        if let factIDRaw = Self.string(body, "factID"), let factID = UUID(uuidString: factIDRaw) {
            store.resolveReview(factID: factID, relatedIDs: relatedIDs,
                                resolution: resolution, mergedText: mergedText)
            return ["ok": true, "mode": "review"]
        }
        if let newText = Self.string(body, "newText"), !newText.isEmpty {
            store.resolveConflict(newText: newText,
                                  category: Self.string(body, "category") ?? "fact",
                                  scope: Self.string(body, "scope") ?? "global",
                                  resolution: resolution, relatedIDs: relatedIDs,
                                  mergedText: mergedText)
            return ["ok": true, "mode": "manual"]
        }
        return ["error": "need factID (review) or newText (manual)"]
    }

    private static func updateMemoryFact(id: String, content: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id), !content.isEmpty else { return ["error": "bad id or content"] }
        AgentMemoryStore.shared.updateFactContent(uuid, content: content)
        return ["ok": true]
    }

    private static func deleteMemoryFact(id: String) throws -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { return ["error": "bad id"] }
        AgentMemoryStore.shared.removeFact(uuid)
        return ["ok": true]
    }

    private static func listSkills() throws -> [String: Any] {
        let skills = SkillStore.shared.skills.map { s -> [String: Any] in
            ["name": s.name, "description": s.description]
        }
        return ["skills": skills]
    }

    private static func reloadSkills() throws -> [String: Any] {
        SkillStore.shared.reload()
        return ["ok": true, "count": SkillStore.shared.skills.count]
    }

    /// 从会话提炼技能草稿（v0.7.22 旗舰的桥等价；与面板路径同一服务）。
    /// 默认只回草稿；save=true 时落盘（<name>.md、同名覆盖）并 reload。
    private static func distillSkill(window: String?, save: Bool) async throws -> [String: Any] {
        guard let session = resolveSession(window) else { return ["error": "no live agent session"] }
        guard let preference = AppState.live?.aiPreference else { return ["error": "app state not ready"] }
        guard let draft = await SkillDistiller.draft(from: session.messages, preference: preference) else {
            return ["error": "distillation failed (conversation too short or model output unparsable)"]
        }
        var payload: [String: Any] = [
            "ok": true, "saved": false,
            "name": draft.name, "description": draft.description,
            "instructions": draft.instructions,
        ]
        if save {
            let url = SkillStore.directory
                .appendingPathComponent(FilePathing.sanitizeFileName(draft.name) + ".md")
            let markdown = SkillAuthoring.markdown(name: draft.name,
                                                   description: draft.description,
                                                   instructions: draft.instructions)
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return ["error": "write failed: \(error.localizedDescription)"]
            }
            SkillStore.shared.reload()
            payload["saved"] = true
            payload["path"] = url.path
        }
        return payload
    }

    private static func deleteSkill(name: String) throws -> [String: Any] {
        guard let skill = SkillStore.shared.skills.first(where: { $0.name == name }) else {
            return ["error": "no such skill"]
        }
        try? FileManager.default.removeItem(at: skill.url)
        SkillStore.shared.reload()
        return ["ok": true]
    }

    /// Imports a skill from an HTTP(S) raw markdown URL. Blocks briefly
    /// (single fetch) so the caller can assert the result.
    private static func importSkill(name: String, url: String) async throws -> [String: Any] {
        guard let url = URL(string: url), url.scheme == "http" || url.scheme == "https" else {
            return ["error": "missing or invalid url"]
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return ["error": "fetch failed"]
        }
        let parsed = SkillStore.parse(text, url: SkillStore.directory.appendingPathComponent("imported.md"))
        let finalName = name.isEmpty ? parsed.name : name
        let file = SkillStore.directory.appendingPathComponent("\(finalName).md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        SkillStore.shared.reload()
        return ["ok": true, "name": finalName]
    }

    private static func setAgentTaskEnabled(name: String, enabled: Bool?) throws -> [String: Any] {
        guard let task = AgentScheduler.shared.tasks.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            return ["error": "no such task"]
        }
        AgentScheduler.shared.setEnabled(enabled ?? !task.isEnabled, for: task.id)
        return ["ok": true, "name": name, "enabled": enabled ?? !task.isEnabled]
    }

    private static func agentRuns(name: String?, count: Int) throws -> [String: Any] {
        var runs = AgentScheduler.shared.runs
        if let name, !name.isEmpty {
            runs = runs.filter { $0.taskName.lowercased() == name.lowercased() }
        }
        let rows = runs.prefix(count).map { r -> [String: Any] in
            [
                "id": r.id.uuidString,
                "task": r.taskName,
                "firedAt": ISO.string(from: r.firedAt),
                "finishedAt": r.finishedAt.map(ISO.string(from:)) ?? "",
                "status": r.status,
                "success": r.success ?? NSNull(),
                "error": r.error ?? "",
                "attempts": r.attempts,
            ]
        }
        return ["runs": Array(rows)]
    }

    private static func approvalPolicies() throws -> [String: Any] {
        ["rules": ApprovalPolicyStore.shared.rules.map { r -> [String: Any] in
            ["tool": r.toolName, "decision": r.decision.rawValue]
        }]
    }

    private static func addApprovalPolicy(toolName: String, decision: String) throws -> [String: Any] {
        guard let d = ApprovalPolicy.Decision(rawValue: decision) else {
            return ["error": "decision must be allow | deny"]
        }
        ApprovalPolicyStore.shared.addRule(toolName: toolName, decision: d)
        return ["ok": true, "tool": toolName, "decision": decision]
    }

    private static func removeApprovalPolicy(toolName: String) throws -> [String: Any] {
        guard let rule = ApprovalPolicyStore.shared.rules.first(where: { $0.toolName == toolName }) else {
            return ["error": "no such rule"]
        }
        ApprovalPolicyStore.shared.removeRule(id: rule.id)
        return ["ok": true]
    }

    private static func approvalHistory(count: Int) throws -> [String: Any] {
        let rows = ApprovalPolicyStore.shared.history.prefix(count).map { h -> [String: Any] in
            ["tool": h.toolName, "decision": h.decision, "source": h.source,
             "at": ISO.string(from: h.createdAt)]
        }
        return ["history": Array(rows)]
    }

    /// Arms a real pending approval on the live session (plumbing E2E
    /// without a model turn); resolve it via POST /approvals/resolve.
    private static func simulateApproval() throws -> [String: Any] {
        guard let session = AgentScheduler.shared.deliveryTarget else {
            return ["error": "no live agent session"]
        }
        session.simulateApprovalForTesting()
        return ["ok": true]
    }
}
