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

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data,
                  let request = String(data: data, encoding: .utf8) else {
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
        ep("POST", "/execute", "Run JS in the page, return result", params: ["js:string", "index?:int"], example: #"-d '{"js":"document.title"}'"#)
        ep("GET", "/screenshot", "PNG of a tab (default selected). inline=1 → base64 in response; otherwise writes ~/desire_automation.png", params: ["index?:int", "inline?:bool"], example: "…/screenshot?index=0&inline=1")
        // Panels & chrome
        ep("POST", "/panel", "Open/close an app panel (downloads)", params: ["name:string", "show?:bool"], example: #"-d '{"name":"downloads","show":true}'"#)
        ep("GET", "/panel/snapshot", "In-process PNG of an open panel (capture-shield safe)", params: ["name:string"], example: "…/panel/snapshot?name=downloads")
        ep("POST", "/command", "Drive any BrowserCommand (menu actions)", params: ["name:string (zoomIn/newTab/bookmarkPage/toggleReader/…)", "index?:int (selectTab)"], example: #"-d '{"name":"newTab"}'"#)
        // Downloads
        ep("GET", "/downloads", "Rows: id/file/state/paused/bytes/total/private", example: "…/downloads")
        ep("POST", "/downloads/pause", "Pause", params: ["id?:uuid"], example: "-d '{}'")
        ep("POST", "/downloads/resume", "Resume", params: ["id?:uuid"], example: "-d '{}'")
        // Data stores
        ep("GET", "/history", "History, newest first", params: ["count?:int"], example: "…/history?count=10")
        ep("GET", "/diag/geometry", "Web view + window frames (fullscreen debugging)", params: ["index?:int"], example: "…/diag/geometry")
        ep("GET", "/bookmarks", "Bookmark leaves", example: "…/bookmarks")
        ep("POST", "/bookmarks/add", "Add bookmark", params: ["title:string", "url:string"], example: #"-d '{"title":"X","url":"https://a.b"}'"#)
        ep("POST", "/bookmarks/remove", "Remove by URL", params: ["url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("GET", "/reading-list", "Reading list", example: "…/reading-list")
        ep("POST", "/reading-list/add", "Add item", params: ["title:string", "url:string"], example: #"-d '{"url":"https://a.b"}'"#)
        ep("POST", "/reading-list/remove", "Remove by URL", params: ["url:string"], example: #"-d '{"url":"https://a.b"}'"#)
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
        ep("GET", "/agent/messages", "Live agent conversation + busy", example: "…/agent/messages")
        ep("POST", "/agent/send", "Prompt the live agent session", params: ["text:string"], example: #"-d '{"text":"summarize this page"}'"#)
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
            case ("GET", "/settings"):
                let st = Settings()
                return try Self.json([
                    "searchEngine": st.searchEngine.rawValue,
                    "httpsUpgradeEnabled": st.httpsUpgradeEnabled,
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
                    show: body["show"] as? Bool
                ))
            case ("GET", "/panel/snapshot"):
                return try Self.json(Self.panelSnapshot(name: query["name"] ?? "downloads"))
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
            case ("POST", "/agent/send"):
                return try Self.json(Self.agentSend(Self.string(body, "text"), window: Self.string(body, "window")))
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

    private static func agentMessages(window: String? = nil) throws -> [String: Any] {
        guard let session = resolveSession(window) else {
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

    private static func agentSend(_ text: String?, window: String?) throws -> [String: Any] {
        guard let text, !text.isEmpty else { return ["error": "missing text"] }
        guard let session = resolveSession(window) else {
            return ["error": "no live agent session"]
        }
        session.sendMessage(text)
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
