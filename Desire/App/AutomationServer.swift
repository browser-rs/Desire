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
        return header.lowercased().contains("bearer \(requiredToken.lowercased())")
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

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
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
                        "example": "curl -s \(method == "GET" ? "" : "-X \(method) ")http://127.0.0.1:8799\(path) → \(example)"])
        }
        // Browsing
        ep("GET", "/state", "All tabs (index/title/url/incognito/selected) + selected + window flags", example: #"{"tabs":[…],"selected":0}"#)
        ep("POST", "/navigate", "Navigate a tab", params: ["url:string (required)", "index?:int"], example: #"-d '{"url":"https://example.com"}'"#)
        ep("POST", "/back", "Go back", params: ["index?:int"], example: "-d '{}'")
        ep("POST", "/forward", "Go forward", params: ["index?:int"], example: "-d '{}'")
        ep("POST", "/reload", "Reload", params: ["index?:int"], example: "-d '{}'")
        ep("POST", "/new-tab", "Open a tab (optionally incognito / in a named container)", params: ["url?:string", "incognito?:bool", "container?:string"], example: #"-d '{"url":"https://example.com","incognito":true}'"#)
        ep("POST", "/close-tab", "Close tab (last tab closes its window)", params: ["index?:int"], example: "-d '{\"index\":1}'")
        ep("POST", "/switch-tab", "Select tab", params: ["index:int"], example: "-d '{\"index\":0}'")
        ep("GET", "/page/text", "Visible page text (≤20k chars)", params: ["index?:int"], example: "…/page/text?index=0")
        ep("GET", "/page/url", "url/title/isLoading/zoom/error", params: ["index?:int"], example: "…/page/url")
        ep("GET", "/page/timing", "Navigation timing (ttfb/load/protocol)", params: ["index?:int"], example: "…/page/timing")
        ep("GET", "/find", "Find in page: matchFound + count", params: ["q:string", "index?:int"], example: "…/find?q=hello")
        ep("GET", "/suggest", "Address-bar suggestions (local rows)", params: ["q:string"], example: "…/suggest?q=git")
        ep("GET", "/conversations/search", "Search saved agent conversations (same code path as the searchConversations tool)", params: ["q:string", "limit?:int"], example: "…/conversations/search?q=github")
        ep("POST", "/conversations/delete", "Delete conversations (cleanup after tests, batch)", params: ["ids:[uuid]", "id?:uuid"], example: #"-d '{"ids":["…"]}'"#)
        ep("GET", "/agent/trace", "Conversation trace as JSONL — one line per turn (goal, steps with per-tool ms, answer, critique, verification, feedback)", params: ["conversation?:uuid (default: live)", "limit?:int"], example: "…/agent/trace?limit=3")
        ep("GET", "/agent/stats", "Token usage statistics derived from saved conversations (same code as the panel's Usage page)", params: ["days?:int (include the daily series)"], example: "…/agent/stats?days=30")
        ep("POST", "/execute", "Run JS in the page, return result", params: ["js:string", "index?:int"], example: #"-d '{"js":"document.title"}'"#)
        ep("GET", "/screenshot", "PNG of a tab (default selected). inline=1 → base64 in response; otherwise writes ~/desire_automation.png", params: ["index?:int", "inline?:bool"], example: "…/screenshot?index=0&inline=1")
        // Panels & chrome
        ep("POST", "/panel", "Open/close an app panel (downloads, devtools+tab)", params: ["name:string", "show?:bool", "tab?:string"], example: #"-d '{"name":"devtools","tab":"network"}'"#)
        ep("GET", "/panel/snapshot", "In-process PNG of an open panel (capture-shield safe)", params: ["name:string (downloads|devtools|agentstats)", "tab?:string (devtools)", "w?/h?:number"], example: "…/panel/snapshot?name=devtools&tab=network")
        ep("POST", "/command", "Drive any BrowserCommand (menu actions)", params: ["name:string (zoomIn/newTab/bookmarkPage/toggleReader/…)", "index?:int (selectTab)"], example: #"-d '{"name":"newTab"}'"#)
        // Downloads
        ep("GET", "/downloads", "Rows: id/file/state/paused/bytes/total/private", example: "…/downloads")
        ep("POST", "/downloads/pause", "Pause", params: ["id?:uuid"], example: "-d '{}'")
        ep("POST", "/downloads/resume", "Resume", params: ["id?:uuid"], example: "-d '{}'")
        // Data stores
        ep("GET", "/history", "History, newest first", params: ["count?:int"], example: "…/history?count=10")
        ep("GET", "/diag/geometry", "Web view + window frames (fullscreen debugging)", params: ["index?:int"], example: "…/diag/geometry")
        ep("POST", "/devtools/eval", "Run JS in the console REPL path", params: ["js:string", "index?:int"], example: #"-d '{"js":"document.title"}'"#)
        ep("POST", "/devtools/inspect", "Fill the Element tab from a selector", params: ["selector:string", "index?:int"], example: #"-d '{"selector":"h1"}'"#)
        ep("GET", "/devtools", "DevTools panel state (scoped counters, tab list, totals)", example: "…/devtools")
        ep("POST", "/devtools/config", "Runtime toggles (console clearing, Application section, tab scope)", params: ["clearConsoleOnNavigate?:bool", "applicationSection?:string", "tabScope?:current|all|<tab uuid>"], example: #"-d '{"tabScope":"all"}'"#)
        ep("POST", "/devtools/preview", "Fetch a page resource via the page (cookies included) and save it as PNG", params: ["url:string", "index?:int"], example: #"-d '{"url":"http://127.0.0.1:8878/pixel.png"}'"#)
        ep("POST", "/devtools/replay", "Re-send a recorded request from the page (same path as the ↻ button)", params: ["url:string", "index?:int"], example: #"-d '{"url":"http://127.0.0.1:8879/api/data"}'"#)
        ep("GET", "/devtools/console/ref", "Expand a console object handle (one level; handles come from console rows)", params: ["ref:string", "index?:int"], example: "…/devtools/console/ref?ref=c1")
        ep("GET", "/devtools/application", "Cookies + web storage of the active tab", params: ["index?:int"], example: "…/devtools/application")
        ep("POST", "/devtools/edit", "Edit inline style/attributes of an element", params: ["selector:string", "style?:json", "attributes?:json"], example: #"-d '{"selector":"h1","style":{"color":"red"}}'"#)
        ep("POST", "/devtools/application/delete", "Delete a cookie/storage/IndexedDB/cache/service worker", params: ["kind:string (cookie|localStorage|sessionStorage|extension|indexedDB|cache|cacheAll|serviceWorker)", "key?:string", "ext?:uuid", "index?:int"], example: #"-d '{"kind":"indexedDB","key":"mydb"}'"#)
        ep("POST", "/devtools/application/set", "Write a cookie / localStorage / sessionStorage / extension key", params: ["kind:string", "key:string", "value:string", "domain?:string (cookies)", "ext?:uuid", "index?:int"], example: #"-d '{"kind":"localStorage","key":"foo","value":"bar"}'"#)
        ep("GET", "/rules", "Video ad-rule sources (builtin/local/remote)", example: "…/rules")
        ep("POST", "/rules/refresh", "Reload local rule overrides + fetch remote bundle", example: "-d '{}'")
        ep("GET", "/bookmarks", "Bookmark leaves", example: "…/bookmarks")
        ep("POST", "/bookmarks/add", "Add bookmark", params: ["title:string", "url:string"], example: #"-d '{"title":"X","url":"https://a.b"}'"#)
        ep("POST", "/bookmarks/remove", "Remove by URL", params: ["url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("GET", "/reading-list", "Reading list", example: "…/reading-list")
        ep("POST", "/reading-list/add", "Add item", params: ["title:string", "url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("POST", "/reading-list/remove", "Remove by URL", params: ["url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("GET", "/sync/status", "Cloud sync state (auth / syncing / lastSyncAt / lastError / per-domain cursors + pending tombstones)", example: "…/sync/status")
        ep("POST", "/sync/now", "Run a full sync cycle (all domains), return resulting status", example: "-d '{}'")
        ep("POST", "/sync/login", "Sign in (then auto-sync at launch + every 5 min)", params: ["username:string", "password:string"], example: #"-d '{"username":"u","password":"p"}'"#)
        ep("POST", "/sync/register", "Create account + sign in", params: ["username:string", "password:string"], example: #"-d '{"username":"u","password":"p"}'"#)
        ep("POST", "/sync/logout", "Sign out on this device (server tokens revoked)", example: "-d '{}'")
        ep("POST", "/sync/server", "Point the sync client at a server base URL (persisted)", params: ["baseURL:string"], example: #"-d '{"baseURL":"http://127.0.0.1:18090"}'"#)
        ep("POST", "/sync/setting", "Write one syncable setting locally (pushed to server on next sync)", params: ["key:string", "string|bool|number:value"], example: #"-d '{"key":"homePage","string":"https://example.com"}'"#)
        ep("POST", "/sync/domain", "Enable/disable a sync category", params: ["domain:string (bookmarks|quickdials|reading_list|keyboard_shortcuts|settings)", "enabled:bool"], example: #"-d '{"domain":"quickdials","enabled":false}'"#)
        ep("POST", "/sync/key", "Generate or import the E2E sync key (generated key is returned once — store it)", params: ["generate?:bool", "key?:string (base64 from another device)"], example: #"-d '{"generate":true}'"#)
        ep("GET", "/search-history", "Recent search queries", params: ["count?:int"], example: "…/search-history?count=5")
        ep("POST", "/search-history/add", "Record a search", params: ["query:string", "engine?:string"], example: #"-d '{"query":"weather"}'"#)
        ep("POST", "/search-history/clear", "Clear search history", example: "-d '{}'")
        ep("GET", "/quickdial", "New-tab quick dial", example: "…/quickdial")
        ep("POST", "/quickdial/add", "Add dial", params: ["title:string", "url:string"], example: #"-d '{"title":"X","url":"https://a.b"}'"#)
        ep("POST", "/quickdial/delete", "Delete by URL", params: ["url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("GET", "/site-settings", "Per-host zoom/darkMode/blockedSelectors", params: ["host:string"], example: "…/site-settings?host=example.com")
        ep("POST", "/site-settings/darkmode", "Set per-host dark mode", params: ["host:string", "enabled:bool"], example: #"-d '{"host":"example.com","enabled":true}'"#)
        ep("POST", "/site-settings/zoom", "Set per-host zoom", params: ["host:string", "zoom:double"], example: #"-d '{"host":"example.com","zoom":1.5}'"#)
        ep("GET", "/elements", "Element-blocker rules", example: "…/elements")
        ep("POST", "/elements/add", "Hide matching CSS on matching hosts", params: ["selector:string", "pattern:string"], example: #"-d '{"selector":"nav","pattern":"example.com"}'"#)
        ep("POST", "/elements/remove", "Remove rule", params: ["selector:string", "pattern:string"], example: "-d '{…}'")
        ep("POST", "/tabs/pin", "Pin/unpin", params: ["index?:int", "pinned?:bool"], example: #"-d '{"index":0,"pinned":true}'"#)
        ep("GET", "/tabgroups", "Tab groups", example: "…/tabgroups")
        ep("POST", "/tabgroups/create", "Create group (optionally absorb tab)", params: ["name:string", "index?:int"], example: #"-d '{"name":"Work","index":1}'"#)
        ep("POST", "/tabgroups/collapse", "Collapse/expand", params: ["name:string", "collapsed?:bool"], example: "-d '{\"name\":\"Work\"}'")
        ep("POST", "/tabgroups/delete", "Delete group (tabs survive)", params: ["name:string"], example: "-d '{\"name\":\"Work\"}'")
        ep("POST", "/containers/remove", "Remove container by name", params: ["name:string"], example: "-d '{\"name\":\"Shop\"}'")
        ep("GET", "/downloads/dangerous", "Pending dangerous-download confirmation (bar)", example: "…/downloads/dangerous")
        ep("POST", "/downloads/dangerous/resolve", "Resolve the confirmation (allow=true reloads the URL as a download)", params: ["allow:bool"], example: "-d '{\"allow\":true}'")
        ep("GET", "/plugins", "User plugin (userscript) list", example: "…/plugins")
        ep("GET", "/webext/debug", "ExtensionEventHub listener count + tab listener flags", example: "…/webext/debug")
        ep("POST", "/webext/fire", "Manually fire an extension tab event (diagnostics)", params: ["event:string"], example: "-d '{\"event\":\"tabs.onActivated\"}'")
        ep("POST", "/webext/eval", "Run JS in the ISOLATED extension world of the selected tab (sees browser.*; /execute cannot)", params: ["js:string"], example: "-d '{\"js\":\"typeof browser\"}'")
        ep("POST", "/plugins/add", "Create a userscript plugin (runs in the isolated extension world with browser.* API)", params: ["name:string", "js:string", "patterns?:array", "runAt?:string(document_start|document_end|document_idle)", "pinned?:bool", "icon?:string(sf-symbol)"], example: "-d '{\"name\":\"t\",\"js\":\"console.log(1)\",\"patterns\":[\"*://127.0.0.1/*\"]}'")
        ep("POST", "/plugins/pin", "Pin/unpin a plugin to the toolbar", params: ["id:string", "pinned:bool"], example: "-d '{\"id\":\"<uuid>\",\"pinned\":true}'")
        ep("POST", "/plugins/install-msex", "Install a .msex package (manifest v3 subset: content_scripts + popup)", params: ["path:string"], example: "-d '{\"path\":\"/tmp/demo.msex\"}'")
        ep("POST", "/plugins/remove", "Remove a plugin", params: ["id:string"], example: "-d '{\"id\":\"<uuid>\"}'")
        ep("GET", "/passwords", "Password metadata + pendingSave (never secrets)", example: "…/passwords")
        ep("POST", "/passwords/add", "Seed a credential (domain/username/password)", params: ["domain:string", "username:string", "password:string"], example: "-d '{\"domain\":\"example.com\",\"username\":\"u\",\"password\":\"p\"}'")
        ep("POST", "/passwords/import", "Import CSV (Chrome format) into the store", params: ["csv:string"], example: "-d '{\"csv\":\"name,url,username,password\\n…\"}'")
        ep("POST", "/passwords/resolve", "Resolve save/update-password prompt", params: ["save:bool"], example: "-d '{\"save\":true}'")
        ep("POST", "/passwords/delete", "Delete credentials for domain", params: ["domain:string"], example: "-d '{\"domain\":\"example.com\"}'")
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
        ep("POST", "/ai/model", "Switch the current model (same path as the input-bar menu)", params: ["model:string"], example: #"-d '{"model":"gpt-4o-mini"}'"#)
        ep("POST", "/ai/models/fetch", "Fetch a service's /models list into its model list (same fetcher the UI uses)", params: ["id?:uuid (default: active)"], example: "-d '{}'")
        ep("POST", "/ai/profiles/delete", "Delete a custom model service (built-ins cannot be deleted)", params: ["id:uuid"], example: #"-d '{"id":"…"}'"#)
        ep("GET", "/ai/prices", "Model price table (USD per Mtok) used to turn token usage into cost", example: "…/ai/prices")
        ep("POST", "/ai/prices", "Set/clear model prices; 0 or omitted = unknown (that model shows no money)", params: ["models?:{model:{input,output}}", "remove?:[model]"], example: #"-d '{"models":{"gpt-4o":{"input":2.5,"output":10}}}'"#)
        ep("GET", "/agent/messages", "Live agent conversation + busy", example: "…/agent/messages")
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
        ep("POST", "/agent/note", "Append a system note to the conversation (not rendered; folded into the system prompt)", params: ["text:string"], example: #"-d '{"text":"Download finished: x.bin"}'"#)
        ep("POST", "/agent/resume", "Re-run the trailing unanswered user prompt (mid-turn crash recovery)", example: "-d '{}'")
        ep("POST", "/agent/cancel", "Stop the running turn (same as Esc in the panel)", example: "-d '{}'")
        ep("POST", "/agent/send", "Prompt the live agent session", params: ["text:string", "recordHistory?:bool (default false)"], example: #"-d '{"text":"summarize this page"}'"#)
        ep("GET", "/agent/tasks", "Scheduled agent tasks", example: "…/agent/tasks")
        ep("GET", "/agent/crew", "Tab Crew status (per-subtask progress + reports)", example: "…/agent/crew")
        ep("POST", "/agent/crew/cancel", "Cancel the whole crew (or one subtask)", params: ["index?:int"], example: "-d '{}'")
        ep("POST", "/agent/crew-dispatch", "Dispatch a crew (objective + subtasks); MCP crewDispatch maps here", params: ["objective:string", "tasks:array"], example: "-d '{\"objective\":\"compare\",\"tasks\":[{\"url\":\"https://a\",\"instruction\":\"price of X\"}]}'")
        ep("POST", "/agent/tasks/create", "Create task", params: ["name:string", "prompt:string", "minutes?:int | hour+minute"], example: #"-d '{"name":"t","prompt":"p","minutes":30}'"#)
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
        ep("POST", "/responsive", "Toggle responsive design mode", params: ["enabled?:bool", "preset?:string", "index?:int"], example: "-d '{\"enabled\":true}'")
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
            "baseUrl": "http://127.0.0.1:8799",
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
            case ("GET", "/"):
                return try Self.json(Self.index())
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
                return try await Self.json(Self.find(query: query["q"] ?? "", index: Self.index(query)))
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
                return try Self.json(Self.history(count: Int(query["count"] ?? "10") ?? 10))
            case ("GET", "/diag/geometry"):
                return try Self.json(Self.geometry(index: Self.index(query)))
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
                tab.responsiveConfig.isEnabled = enabled   // onChange → Applier
                return try Self.json(["ok": true, "size": tab.responsiveConfig.effectiveSize])
            case ("GET", "/approvals"):
                return try Self.json(Self.pendingApproval(window: Self.string(query, "window")))
            case ("GET", "/beforeunload"):
                return try Self.json(Self.beforeUnloadState(index: Self.index(query)))
            case ("GET", "/reader"):
                return try Self.json(Self.readerState(index: Self.index(query)))
            case ("GET", "/console"):
                return try Self.json(Self.console(count: Int(query["count"] ?? "20") ?? 20))
            case ("GET", "/plugins"):
                return try Self.json(Self.pluginList())
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
                    icon: Self.string(body, "icon")
                ))
            case ("POST", "/plugins/install-msex"):
                guard let app = AppState.live else { return try Self.json(["error": "app state not ready"]) }
                let path = Self.string(body, "path") ?? ""
                guard FileManager.default.fileExists(atPath: path) else {
                    return try Self.json(["error": "file not found: \(path)"])
                }
                do {
                    let result = try MSExInstaller.install(from: URL(fileURLWithPath: path), store: app.pluginStore)
                    return try Self.json([
                        "ok": true,
                        "id": result.plugin.id.uuidString,
                        "name": result.plugin.name,
                        "hasPopup": result.plugin.popupHTML != nil,
                    ])
                } catch {
                    return try Self.json(["error": error.localizedDescription])
                }
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
                return try Self.json(Self.deletePasswords(domain: Self.string(body, "domain") ?? ""))
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
                return try Self.json(Self.removeBookmark(url: Self.string(body, "url") ?? ""))
            case ("POST", "/tabs/pin"):
                return try Self.json(Self.setPin(index: Self.index(body), pinned: body["pinned"] as? Bool))
            case ("GET", "/reading-list"):
                return try Self.json(Self.readingList())
            case ("POST", "/reading-list/add"):
                return try Self.json(Self.addReadingItem(
                    title: Self.string(body, "title") ?? "",
                    url: Self.string(body, "url") ?? ""
                ))
            case ("POST", "/reading-list/remove"):
                return try Self.json(Self.removeReadingItem(url: Self.string(body, "url") ?? ""))
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
            case ("POST", "/sync/setting"):
                return try Self.json(Self.syncSetSetting(body))
            case ("POST", "/sync/domain"):
                return try Self.json(Self.syncSetDomain(body))
            case ("POST", "/sync/key"):
                return try Self.json(await Self.syncSetKey(body))
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
                    window: Self.string(body, "window")
                ))
            case ("POST", "/devtools/eval"):
                return try await Self.json(Self.devToolsEval(js: Self.string(body, "js") ?? "", index: Self.index(body)))
            case ("POST", "/devtools/inspect"):
                return try await Self.json(Self.devToolsInspect(selector: Self.string(body, "selector") ?? "", index: Self.index(body)))
            case ("GET", "/devtools"):
                return try Self.json(Self.devToolsState())
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
                    key: Self.string(body, "key")
                ))
            case ("POST", "/ai/models/fetch"):
                return try await Self.json(Self.aiFetchModels(id: Self.string(body, "id")))
            case ("POST", "/ai/model"):
                return try Self.json(Self.aiSetModel(Self.string(body, "model") ?? ""))
            case ("POST", "/ai/profiles/activate"):
                return try Self.json(Self.aiProfileActivate(id: Self.string(body, "id") ?? ""))
            case ("POST", "/ai/profiles/delete"):
                return try Self.json(Self.aiProfileDelete(id: Self.string(body, "id") ?? ""))
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
                return try Self.json(Self.addMCPServer(
                    name: Self.string(body, "name") ?? "",
                    url: Self.string(body, "url") ?? ""
                ))
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
                return try Self.json(["servers": servers, "tools": store.toolDefs.map(\.function.name)])
            case ("GET", "/downloads"):
                return try Self.json(Self.downloads())
            case ("POST", "/downloads/batch"):
                return try Self.json(Self.batchDownload(urls: body["urls"] as? [String] ?? []))
            case ("POST", "/downloads/start"):
                return try Self.json(Self.startDownload(Self.string(body, "url") ?? ""))
            case ("POST", "/downloads/pause"):
                return try Self.json(Self.pauseDownload(Self.string(body, "id")))
            case ("POST", "/downloads/resume"):
                return try Self.json(Self.resumeDownload(Self.string(body, "id")))
            case ("POST", "/execute"):
                return try await Self.json(Self.execute(Self.string(body, "js") ?? "", index: Self.index(body)))
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
                return try Self.json(Self.bookmarks())
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
                    minutes: body["minutes"] as? Int ?? 5
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
            case ("GET", "/agent/windows"):
                return try Self.json(Self.agentWindows())
            case ("GET", "/agent/messages"):
                return try Self.json(Self.agentMessages(window: Self.string(query, "window")))
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
            case ("POST", "/agent/note"):
                return try Self.json(Self.agentNote(
                    text: Self.string(body, "text") ?? "",
                    window: Self.string(body, "window")
                ))
            case ("POST", "/conversations/delete"):
                return try Self.json(Self.deleteConversations(body))
            case ("POST", "/agent/feedback"):
                return try Self.json(Self.setAgentFeedback(
                    messageId: Self.string(body, "messageId") ?? "",
                    vote: Self.string(body, "vote") ?? ""))
            case ("POST", "/agent/resume"):
                return try Self.json(Self.agentResume(window: Self.string(body, "window")))
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
                return try Self.json(["result": AgentCrewStore.shared.dispatch(
                    objective: objective, tasks: tasks, surface: surface)])
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
                    minute: body["minute"] as? Int
                ))
            case ("POST", "/agent/tasks/remove"):
                return try Self.json(Self.removeAgentTask(name: Self.string(body, "name") ?? ""))
            case ("POST", "/agent/tasks/fire"):
                return try Self.json(Self.fireAgentTask(name: Self.string(body, "name") ?? ""))
            case ("POST", "/memory/search"):
                return try Self.json(Self.searchMemory(query: Self.string(body, "query") ?? ""))
            case ("POST", "/memory/export"):
                return try Self.json(Self.exportMemory())
            case ("POST", "/memory/decay"):
                return try Self.json(Self.decayMemory(olderThanDays: body["days"] as? Int ?? 90))
            case ("GET", "/memory"):
                return try Self.json(Self.memorySnapshot())
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
            case ("GET", "/skills"):
                return try Self.json(Self.listSkills())
            case ("POST", "/skills/reload"):
                return try Self.json(Self.reloadSkills())
            case ("POST", "/skills/delete"):
                return try Self.json(Self.deleteSkill(name: Self.string(body, "name") ?? ""))
            case ("POST", "/skills/import"):
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

    // MARK: - Accessors

    private var tabManager: TabManager? {
        get throws { TabSessionCoordinator.shared.activeTabManager }
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
            ]
        }
        return [
            "tabs": tabs,
            "selected": tm?.selectedIndex ?? -1,
            "agentBusy": AgentScheduler.shared.deliveryTarget?.isProcessing ?? false,
            "isActive": NSApp.isActive,
            "hasKeyWindow": NSApp.keyWindow != nil,
            // Agent 的文件工具以这个目录为工作区——自动化/评估要把 fixture
            // 放进它才能免审批被 readFile 读到。
            "agentWorkspace": SystemCommandStore.shared.workingDirectoryText,
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
                ISO8601DateFormatter().string(from: $0)
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
        let entries = historyStore.entries.prefix(count).map { ["title": $0.title, "url": $0.url] }
        return ["entries": Array(entries)]
    }

    private static func bookmarks() throws -> [String: Any] {
        // 新实例须落在当前活跃人物的桶上（0.3.5），否则永远读默认桶。
        let store = BookmarkStore()
        store.applyScope(profileID: ProfileStore.shared.activeProfileID)
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
        case "showExtensions": command = .showExtensions
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
        case "toggleSplitView": command = .toggleSplitView
        case "toggleDevTools": command = .toggleDevTools
        case "addToReadingList": command = .addToReadingList
        case "askAgentAboutPage": command = .askAgentAboutPage
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
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let visible = show ?? !app.showDownloadsPanel
        app.showDownloadsPanel = visible
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
        if name == "agentstats" {
            // Agent 面板的"使用统计"页：同样当场渲染（面板在主窗分栏里）。尺寸可指定——
            // 这一页在**窄面板**下最容易挤坏，要能按 420/900 两种宽度各拍一张。
            return try await agentStatsSnapshot(width: width ?? 420, height: height ?? 900)
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
    private static func find(query: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index), !query.isEmpty else {
            return ["error": "no such tab or empty query"]
        }
        let config = WKFindConfiguration()
        config.wraps = false
        let found: Bool = await withCheckedContinuation { continuation in
            tab.browser.webView.find(query, configuration: config) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        let count: Int = await withCheckedContinuation { continuation in
            tab.browser.webView.evaluateJavaScript(WebView.findCountJS(query: query)) { value, _ in
                continuation.resume(returning: (value as? Int) ?? 0)
            }
        }
        return ["matchFound": found, "count": count]
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
    private static func pluginAdd(name: String, js: String, patterns: [String], runAt: String, css: String, pinned: Bool, icon: String?) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !js.isEmpty else {
            return ["error": "missing name/js"]
        }
        let plugin = Plugin(
            name: name,
            urlPatterns: patterns.isEmpty ? ["*"] : patterns,
            runAt: RunAt(rawValue: runAt) ?? .documentEnd,
            jsCode: js,
            cssCode: css,
            pinned: pinned,
            icon: icon
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

    /// Deletes every saved credential for a domain (test cleanup).
    private static func deletePasswords(domain: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let victims = app.passwordStore.find(domain: domain)
        for entry in victims {
            app.passwordStore.delete(entry)
        }
        return ["ok": true, "deleted": victims.count]
    }

    // MARK: Site settings / QuickDial / Element blocker

    private static func siteSettings(host: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.siteSettingsStore
        guard !host.isEmpty else { return ["error": "missing host"] }
        return ["host": host,
                "zoom": store.zoom(for: host),
                "darkMode": store.darkModeEnabled(for: host),
                "blockedSelectors": store.blockedSelectors(for: host)]
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
            ],
            "enabled": Dictionary(
                uniqueKeysWithValues: SyncDomain.allCases.map { ($0.rawValue, app.syncStore.isEnabled($0)) }
            ),
            "cursors": cursors,
            "pendingDeletions": [
                "bookmarks": app.bookmarkStore.pendingDeletions.count,
                "quickdials": app.quickDialStore.pendingDeletions.count,
                "reading_list": app.readingListStore.pendingDeletions.count,
            ],
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

    /// 生成或导入 E2E 同步密钥。generate=true 时返回一次性的 key（base64），
    /// 调用方需自行保存;import 走服务端指纹校验（不一致报 409 语义错误）。
    private static func syncSetKey(_ body: [String: Any]) async -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        do {
            var generatedKey: String?
            if body["generate"] as? Bool == true {
                generatedKey = try app.syncStore.generateSyncKey()
            } else if let key = Self.string(body, "key") {
                try app.syncStore.importSyncKey(key)
            } else {
                return ["error": "missing key or generate"]
            }
            try await app.syncStore.uploadKeyCheck()
            var out = syncStatus()
            if let generatedKey { out["key"] = generatedKey }
            return out
        } catch {
            return ["error": error.localizedDescription]
        }
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
        let store = ConversationStore()
        let hits = store.search(query, limit: min(20, max(1, limit)))
        let iso = ISO8601DateFormatter()
        return ["query": query, "count": hits.count, "hits": hits.map { hit in
            ["id": hit.id.uuidString, "title": hit.title,
             "updatedAt": iso.string(from: hit.updatedAt),
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
        // 删掉的是**正在面板里显示的**那个会话时如实说明：面板内存里还留着那些消息，
        // 下一回合收尾落盘会把文件写回来（与历史列表里删当前会话的行为一致）。
        if let liveID = live?.conversationId, hit.contains(liveID) {
            result["liveConversationDeleted"] = true
        }
        return result
    }

    /// Token 使用统计（面板的统计页与这里共用 `UsageStats` 派生，同一份会话数据）。
    /// `days=N` 时附带最近 N 天的逐日序列（画图/对账用）。
    @MainActor
    private static func usageStats(days: Int?) -> [String: Any] {
        // 查询用**读盘的新实例**（与 /conversations/search、/agent/trace 同一约定）。
        let store = ConversationStore()
        let preference = AppState.live?.aiPreference
        let stats = UsageStats.derive(from: store.conversations,
                                      price: { preference?.usagePrice(for: $0) })
        var payload: [String: Any] = [
            "totalTokens": stats.totalTokens,
            "promptTokens": stats.promptTokens,
            "completionTokens": stats.completionTokens,
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
            payload["peakDay"] = ISO8601DateFormatter().string(from: peak)
        }
        if let days, days > 0 {
            let iso = ISO8601DateFormatter()
            payload["days"] = stats.recentDays(min(days, 366)).map { day -> [String: Any] in
                ["date": iso.string(from: day.id), "tokens": day.tokens, "turns": day.turns,
                 "byModel": day.byModel]
            }
        }
        return payload
    }

    private static func suggest(query: String) throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let model = AddressSuggestionsModel()
        model.build(query: query, settings: app.settings,
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
    private static func removeBookmark(url: String) throws -> [String: Any] {
        guard let app = AppState.live, !url.isEmpty else { return ["error": "missing url"] }
        guard let bookmark = app.bookmarkStore.find(url: url) else {
            return ["error": "no such bookmark"]
        }
        app.bookmarkStore.remove(bookmark)
        return ["ok": true]
    }

    // MARK: Pins / reading list / search history

    private static func setPin(index: Int?, pinned: Bool?) throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        tab.isPinned = pinned ?? !tab.isPinned
        return ["ok": true, "index": index ?? -1, "pinned": tab.isPinned]
    }

    private static func readingList() throws -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        return ["items": app.readingListStore.items.map { i -> [String: Any] in
            ["title": i.title, "url": i.url, "read": i.isRead]
        }]
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
    private static func resolvePendingApproval(_ decision: String, window: String? = nil) throws -> [String: Any] {
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
        session.resolveApproval(outcome)
        return ["ok": true, "resolved": decision]
    }

    /// 轨迹导出：一行一个回合的 JSONL（从会话派生，含每个工具的耗时）。
    @MainActor
    private static func agentTrace(conversation: String?, limit: Int?) -> [String: Any] {
        let store = ConversationStore()
        var target: Conversation?
        if let conversation, let id = UUID(uuidString: conversation) {
            target = store.conversations.first { $0.id == id }
        } else if let id = AgentScheduler.shared.deliveryTarget?.conversationId {
            target = store.conversations.first { $0.id == id }
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
        let store = ConversationStore()
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
            return item
        }
        return [
            "messages": Array(messages),
            "busy": session.isProcessing,
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

    private static func agentWindows() throws -> [String: Any] {
        let windows = AgentScheduler.shared.liveSessions().map { entry -> [String: Any] in
            guard let session = entry.store else { return ["id": entry.id.uuidString] }
            return [
                "id": entry.id.uuidString,
                "label": entry.displayLabel,
                "busy": session.isProcessing,
                "pendingApproval": session.pendingApproval != nil,
                "messages": session.messages.count,
                "isNewest": AgentScheduler.shared.deliveryTarget === session,
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
                if let last = list.lastUpdated { row["lastUpdated"] = ISO8601DateFormatter().string(from: last) }
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
                    "startedAt": ISO8601DateFormatter().string(from: job.startedAt),
                ]
                if let summary = job.summary { row["summary"] = summary }
                if let finished = job.finishedAt { row["finishedAt"] = ISO8601DateFormatter().string(from: finished) }
                return row
            },
        ]
    }

    private static func mediaExportCancel(id: String) -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { return ["error": "bad id"] }
        MediaExportStore.shared.cancel(id: uuid)
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

    /// 停掉正在跑的一轮（等价于面板里的 Esc / Stop）。
    private static func agentCancel(window: String?) throws -> [String: Any] {
        guard let session = resolveSession(window) else {
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

    private static func createAgentTask(name: String, prompt: String, minutes: Int?, hour: Int?, minute: Int?) throws -> [String: Any] {
        let recurrence: AgentScheduler.ScheduledTask.Recurrence
        if let minutes {
            recurrence = .everyMinutes(minutes)
        } else if let hour, let minute {
            recurrence = .daily(hour: hour, minute: minute)
        } else {
            return ["error": "need minutes, or hour+minute"]
        }
        guard AgentScheduler.shared.add(name: name, prompt: prompt, recurrence: recurrence) != nil else {
            return ["error": "invalid name or prompt"]
        }
        return ["ok": true, "name": name]
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
        Task { @MainActor in
            do {
                let result = try await MediaExporter.download(
                    url: sourceURL, referer: refererURL, userAgent: nil,
                    fileNameHint: fileNameHint, maxBandwidth: maxBandwidth,
                    progress: { _, _ in }
                )
                Log.agent.info("media download finished: \(url, privacy: .public) → \(String(describing: result), privacy: .public)")
            } catch {
                Log.agent.error("media download failed: \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return ["ok": true, "started": url]
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
        return ["watches": store.watches.map { w -> [String: Any] in
            ["name": w.name, "url": w.url, "selector": w.selector ?? "",
             "minutes": w.intervalMinutes, "enabled": w.isEnabled,
             "changeCount": w.changeCount, "lastError": w.lastError ?? ""]
        }]
    }

    private static func addWatch(name: String, url: String, selector: String?, minutes: Int) throws -> [String: Any] {
        guard PageWatchStore.shared.add(name: name, url: url, selector: selector, minutes: minutes) != nil else {
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
        return ["ok": true, "name": name, "changed": changed]
    }

    // MARK: Memory + skills management (0.1.15)

    private static func searchMemory(query: String) throws -> [String: Any] {
        let results = AgentMemoryStore.shared.searchFacts(query: query)
        let formatter = ISO8601DateFormatter()
        return ["results": results.map { f -> [String: Any] in
            ["id": f.id.uuidString, "content": f.content, "category": f.category,
             "pinned": f.pinned, "scope": f.scope, "updatedAt": formatter.string(from: f.updatedAt)]
        }]
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
        let formatter = ISO8601DateFormatter()
        return [
            "profile": [
                "name": store.profileSnapshot.name, "language": store.profileSnapshot.language,
                "style": store.profileSnapshot.style, "customInstructions": store.profileSnapshot.customInstructions,
            ],
            "facts": store.factsSnapshot.map { f -> [String: Any] in
                ["id": f.id.uuidString, "content": f.content, "category": f.category,
                 "pinned": f.pinned, "scope": f.scope, "updatedAt": formatter.string(from: f.updatedAt)]
            },
            "summaries": store.summariesCount,
        ]
    }

    private static func addMemoryFact(content: String, category: String, scope: String) throws -> [String: Any] {
        guard !content.isEmpty else { return ["error": "missing content"] }
        AgentMemoryStore.shared.addFact(content: content, category: category, scope: scope)
        return ["ok": true]
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
        let formatter = ISO8601DateFormatter()
        let rows = runs.prefix(count).map { r -> [String: Any] in
            [
                "id": r.id.uuidString,
                "task": r.taskName,
                "firedAt": formatter.string(from: r.firedAt),
                "finishedAt": r.finishedAt.map(formatter.string(from:)) ?? "",
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
        let formatter = ISO8601DateFormatter()
        let rows = ApprovalPolicyStore.shared.history.prefix(count).map { h -> [String: Any] in
            ["tool": h.toolName, "decision": h.decision, "source": h.source,
             "at": formatter.string(from: h.createdAt)]
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
