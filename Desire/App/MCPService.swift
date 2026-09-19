import Foundation
import Network
import os

/// Desire as an MCP (Model Context Protocol) server over Streamable HTTP.
/// External AI clients — Claude Desktop, any MCP client — connect to
/// `http://127.0.0.1:8798/mcp` and drive the browser through JSON-RPC tool
/// calls. Tool implementations reuse the automation bridge's endpoint
/// pipeline (one source of truth), gated behind the `--mcp-server` launch
/// argument. Port 8798 keeps it out of the automation bridge's way (8799).
@MainActor
final class MCPService {
    static let shared = MCPService()

    private var listener: NWListener?
    private static let port: UInt16 = 8798
    /// One session per server lifetime is enough for v1 — the id is handed
    /// out at initialize and echoed back by compliant clients.
    private var sessionID = UUID().uuidString
    /// 本连接绑定的 Desire 窗口（initialize 时声明；nil = newest 语义）。
    private var sessionWindowID: String?
    /// Optional bearer auth: `--mcp-token <token>` gates every request
    /// (initialize included) exactly like the automation bridge's
    /// `--automation-token`. Default: open on localhost.
    private static let requiredToken: String? = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--mcp-token"), i + 1 < args.count {
            return args[i + 1]
        }
        if let i = args.firstIndex(where: { $0.hasPrefix("--mcp-token=") }) {
            return String(args[i].dropFirst("--mcp-token=".count))
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

    func startIfRequested() {
        guard CommandLine.arguments.contains("--mcp-server"), listener == nil else { return }
        start()
    }

    private func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: Self.port)!
        )
        guard let listener = try? NWListener(using: params) else {
            Log.agent.error("mcp server: port \(Self.port) unavailable")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handle(connection)
            }
        }
        listener.start(queue: .main)
        Log.agent.info("mcp server ready on 127.0.0.1:\(Self.port)/mcp")
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        accumulate(connection, Data())
    }

    /// Reads until a complete request is buffered. URLSession writes headers
    /// and body as SEPARATE TCP segments — a single receive returns headers
    /// only and produced "400 bad json" for every real MCP client.
    private func accumulate(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { chunk, _, isComplete, error in
            Task { @MainActor in
                let accumulated = buffer + (chunk ?? Data())

                // Complete when headers are parsed and body bytes match
                // Content-Length (or the peer half-closed with data buffered).
                if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                    let headerText = String(data: accumulated[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                    let declared = headerText
                        .split(separator: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }?
                        .split(separator: ":").last
                        .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                    let bodyCount = accumulated.count - headerEnd.upperBound
                    if bodyCount >= declared {
                        if Self.isAuthorized(String(data: accumulated, encoding: .utf8) ?? "") {
                            self.handleComplete(connection, accumulated)
                        } else {
                            self.respond(connection, status: "401 Unauthorized", body: #"{"error":"unauthorized — missing or wrong bearer token"}"#)
                        }
                        return
                    }
                } else if error != nil || isComplete {
                    connection.cancel()
                    return
                }
                if error != nil || isComplete {
                    connection.cancel()
                    return
                }
                self.accumulate(connection, accumulated)
            }
        }
    }

    private func handleComplete(_ connection: NWConnection, _ buffer: Data) {
        guard let raw = String(data: buffer, encoding: .utf8) else {
            respond(connection, status: "400 Bad Request", body: #"{"error":"bad encoding"}"#)
            return
        }
        if raw.hasPrefix("GET ") {
            // Server→client push: BridgeEventBus events relayed as
            // JSON-RPC notifications on an SSE stream.
            startEventPush(connection)
            return
        }
        if raw.hasPrefix("DELETE ") {
            respond(connection, status: "200 OK", body: "{}")
            return
        }
        guard let bodyStart = raw.range(of: "\r\n\r\n").map({ raw[$0.upperBound...] }),
              let rpc = try? JSONSerialization.jsonObject(with: Data(bodyStart.utf8)) as? [String: Any] else {
            respond(connection, status: "400 Bad Request", body: #"{"error":"bad json"}"#)
            return
        }
        Task { @MainActor in
            let (status, body, _) = await self.dispatch(rpc)
            self.respond(connection, status: status, body: body, extraHeaders: self.sessionHeaders)
        }
    }

    private var sessionHeaders: String {
        "Mcp-Session-Id: \(sessionID)\r\n"
    }

    private func respond(_ connection: NWConnection, status: String, body: String, extraHeaders: String = "") {
        let bodyData = body.data(using: .utf8) ?? Data()
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n\(extraHeaders)Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: head.data(using: .utf8)! + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Server→client event push

    private var eventPushConnections: [UUID: NWConnection] = [:]

    /// GET /mcp — SSE stream relaying BridgeEventBus events as JSON-RPC
    /// notifications (`desire/event`), plus a 15 s keep-alive comment.
    private func startEventPush(_ connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: head.data(using: .utf8)!, completion: .contentProcessed { _ in })
        let busID = BridgeEventBus.shared.subscribe { [weak connection] frame in
            // Rewrite SSE frames (event:/data:) into a JSON-RPC notification.
            guard let eventRange = frame.range(of: "event: "),
                  let dataRange = frame.range(of: "data: ") else { return }
            let kind = String(frame[eventRange.upperBound...].prefix(while: { !$0.isNewline }))
            let json = String(frame[dataRange.upperBound...].prefix(while: { !$0.isNewline }))
            var payload = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
            payload["kind"] = kind
            let notification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "desire/event",
                "params": payload,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: notification)) ?? Data()
            connection?.send(content: Data("event: message\ndata: ".utf8) + data + Data("\n\n".utf8), completion: .contentProcessed { _ in })
        }
        eventPushConnections[busID] = connection

        let heartbeat = Task { [weak connection] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                connection?.send(content: Data(": keep-alive\n\n".utf8), completion: .contentProcessed { _ in })
            }
        }
        eventPushHeartbeats[busID] = heartbeat

        drainPush(connection, busID: busID)
        Log.agent.info("mcp server: event push opened")
    }

    private var eventPushHeartbeats: [UUID: Task<Void, Never>] = [:]

    /// Continues draining an event-push SSE connection (main actor).
    private func drainPush(_ connection: NWConnection, busID: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { _, _, _, error in
            Task { @MainActor in
                if error == nil {
                    self.drainPush(connection, busID: busID)
                } else {
                    BridgeEventBus.shared.unsubscribe(busID)
                    self.eventPushConnections.removeValue(forKey: busID)
                    self.eventPushHeartbeats.removeValue(forKey: busID)?.cancel()
                    connection.cancel()
                }
            }
        }
    }

    // MARK: - JSON-RPC dispatch

    private func dispatch(_ rpc: [String: Any]) async -> (status: String, body: String, isNotification: Bool) {
        let method = rpc["method"] as? String ?? ""
        let id: Any? = rpc["id"]
        let isNotification = (id == nil)
        let params = rpc["params"] as? [String: Any] ?? [:]

        // 会话绑定窗口：客户端 initialize 时声明 _meta.desireWindow（窗口
        // 会话 UUID），后续该连接的工具调用默认作用于那个窗口；工具参数
        // 里的 window 字段可覆盖（per-call 优先）。
        if method == "initialize",
           let meta = params["_meta"] as? [String: Any],
           let windowID = meta["desireWindow"] as? String {
            sessionWindowID = windowID
        }

        // Notifications get 202 Accepted, no body.
        if isNotification {
            return ("202 Accepted", "", true)
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "Desire", "version": "0.1.6"],
            ]
            return ("200 OK", Self.rpcResult(id: id, result: result), false)

        case "ping":
            return ("200 OK", Self.rpcResult(id: id, result: [:]), false)

        case "tools/list":
            let publicTools = Self.toolCatalog.map { tool in
                tool.filter { !$0.key.hasPrefix("_") }
            }
            return ("200 OK", Self.rpcResult(id: id, result: ["tools": publicTools]), false)

        case "tools/call":
            let name = params["name"] as? String ?? ""
            var args = params["arguments"] as? [String: Any] ?? [:]
            // 窗口绑定：per-call window 参数 > 会话绑定 windowID。
            if sessionWindowID != nil, args["window"] == nil {
                args["window"] = sessionWindowID
            }
            guard let tool = Self.toolCatalog.first(where: { $0["name"] as? String == name }),
                  let mapping = tool["_bridge"] as? [String: Any] else {
                return ("200 OK", Self.rpcError(id: id, code: -32602, message: "unknown tool \(name)"), false)
            }
            let httpMethod = mapping["method"] as? String ?? "GET"
            let path = Self.resolvePath(mapping["path"] as? String ?? "", args)
            // Body fields map as {"<bridge field>": "<args field>"}; the
            // "const" map injects fixed values (e.g. kind: "table").
            var payload: [String: Any] = [:]
            for (field, value) in (mapping["const"] as? [String: Any]) ?? [:] {
                payload[field] = value
            }
            for (bridgeField, argsField) in (mapping["body"] as? [String: String]) ?? [String: String]() {
                if let value = args[argsField] {
                    payload[bridgeField] = value
                }
            }
            let bridgeResponse = await AutomationServer.shared.callEndpoint(
                method: httpMethod, path: path, json: payload.isEmpty ? nil : payload,
                window: sessionWindowID
            )
            // Bridge marks failures with a non-null string "error" field;
            // "error": null is normal payload (e.g. pageMeta).
            let parsed = try? JSONSerialization.jsonObject(with: Data(bridgeResponse.utf8)) as? [String: Any]
            let isError = (parsed?["error"] as? String) != nil
            let result: [String: Any] = [
                "content": [["type": "text", "text": bridgeResponse]],
                "isError": isError,
            ]
            return ("200 OK", Self.rpcResult(id: id, result: result), false)

        default:
            return ("200 OK", Self.rpcError(id: id, code: -32601, message: "method not found: \(method)"), false)
        }
    }

    /// Substitutes `{field}` path templates with argument values
    /// (URL-escaped), e.g. "/find?q={q}".
    private static func resolvePath(_ path: String, _ args: [String: Any]) -> String {
        var result = path
        for (field, value) in args {
            let placeholder = "{\(field)}"
            guard result.contains(placeholder) else { continue }
            let rendered: String
            if let scalar = value as? String {
                rendered = scalar.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scalar
            } else {
                rendered = "\(value)"
            }
            result = result.replacingOccurrences(of: placeholder, with: rendered)
        }
        return result
    }

    private static func rpcResult(id: Any?, result: [String: Any]) -> String {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        return Self.json(payload)
    }

    private static func rpcError(id: Any?, code: Int, message: String) -> String {
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ]
        return Self.json(payload)
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Tool catalog

    /// v1 tool set — each tool maps onto one automation-bridge endpoint
    /// (`_bridge` drives the dispatch); descriptions are written for LLMs.
    private static let toolCatalog: [[String: Any]] = [
        [
            "name": "navigate",
            "description": "Navigate the active browser tab to a URL (bare domains are auto-resolved, queries become searches). Waits for navigation to start; poll getPageInfo/getPageText for the result.",
            "inputSchema": [
                "type": "object",
                "properties": ["url": ["type": "string", "description": "URL or search query"]],
                "required": ["url"],
            ],
            "_bridge": ["method": "POST", "path": "/navigate", "body": ["url": "url"]],
        ],
        [
            "name": "getPageText",
            "description": "Visible text content of a tab (≤20k chars). Primary way to read a page.",
            "inputSchema": [
                "type": "object",
                "properties": ["index": ["type": "integer", "description": "Tab index; defaults to the active tab"]],
            ],
            "_bridge": ["method": "GET", "path": "/page/text"],
        ],
        [
            "name": "getPageInfo",
            "description": "Current url/title/isLoading/zoom of a tab.",
            "inputSchema": [
                "type": "object",
                "properties": ["index": ["type": "integer", "description": "Tab index; defaults to the active tab"]],
            ],
            "_bridge": ["method": "GET", "path": "/page/url"],
        ],
        [
            "name": "listTabs",
            "description": "List all open tabs with index/title/url and which is selected.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/state"],
        ],
        [
            "name": "newTab",
            "description": "Open a new tab (optionally incognito) and optionally navigate it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string"],
                    "incognito": ["type": "boolean"],
                ],
            ],
            "_bridge": ["method": "POST", "path": "/new-tab", "body": ["url": "url", "incognito": "incognito"]],
        ],
        [
            "name": "closeTab",
            "description": "Close a tab (defaults to the active one).",
            "inputSchema": [
                "type": "object",
                "properties": ["index": ["type": "integer"]],
            ],
            "_bridge": ["method": "POST", "path": "/close-tab", "body": ["index": "index"]],
        ],
        [
            "name": "switchTab",
            "description": "Make a tab the active one.",
            "inputSchema": [
                "type": "object",
                "properties": ["index": ["type": "integer", "description": "Tab index"]],
                "required": ["index"],
            ],
            "_bridge": ["method": "POST", "path": "/switch-tab", "body": ["index": "index"]],
        ],
        [
            "name": "findInPage",
            "description": "Find text in the page: whether it matches and the total occurrence count.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
            "_bridge": ["method": "GET", "path": "/find?q={query}"],
        ],
        [
            "name": "executeJs",
            "description": "Evaluate JavaScript in the page and return the JSON-encoded result. Power tool — prefer getPageText/getPageInfo when they suffice.",
            "inputSchema": [
                "type": "object",
                "properties": ["js": ["type": "string", "description": "JavaScript expression/statement"]],
                "required": ["js"],
            ],
            "_bridge": ["method": "POST", "path": "/execute", "body": ["js": "js"]],
        ],
        // v2 — downloads, retrieval, guards
        [
            "name": "startDownload",
            "description": "Start downloading a file from a URL (store-owned transfer with pause/resume support). Progress arrives via downloadStarted/downloadCompleted events.",
            "inputSchema": [
                "type": "object",
                "properties": ["url": ["type": "string"]],
                "required": ["url"],
            ],
            "_bridge": ["method": "POST", "path": "/downloads/start", "body": ["url": "url"]],
        ],
        [
            "name": "listDownloads",
            "description": "List download rows (id/file/state/paused/bytes/total).",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/downloads"],
        ],
        [
            "name": "pauseDownload",
            "description": "Pause a download (defaults to the first in-progress one).",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Download id (from listDownloads)"]],
            ],
            "_bridge": ["method": "POST", "path": "/downloads/pause", "body": ["id": "id"]],
        ],
        [
            "name": "resumeDownload",
            "description": "Resume a paused download (defaults to the first paused one).",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"]],
            ],
            "_bridge": ["method": "POST", "path": "/downloads/resume", "body": ["id": "id"]],
        ],
        [
            "name": "listHistory",
            "description": "Recent browsing history, newest first.",
            "inputSchema": [
                "type": "object",
                "properties": ["count": ["type": "integer", "description": "Default 10"]],
            ],
            "_bridge": ["method": "GET", "path": "/history?count={count}"],
        ],
        [
            "name": "listBookmarks",
            "description": "List saved bookmarks.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/bookmarks"],
        ],
        [
            "name": "addBookmark",
            "description": "Save a bookmark.",
            "inputSchema": [
                "type": "object",
                "properties": ["title": ["type": "string"], "url": ["type": "string"]],
                "required": ["url"],
            ],
            "_bridge": ["method": "POST", "path": "/bookmarks/add", "body": ["title": "title", "url": "url"]],
        ],
        // 0.1.10 — page watches
        [
            "name": "watchPage",
            "description": "Watch a page for changes: re-checks it every N minutes (min 5) offscreen and reports diffs via pageWatchChanged events. First check establishes the baseline.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "url": ["type": "string"],
                    "selector": ["type": "string", "description": "Optional CSS selector to watch instead of the whole page"],
                    "minutes": ["type": "integer"],
                ],
                "required": ["name", "url"],
            ],
            "_bridge": ["method": "POST", "path": "/watches/add", "body": ["name": "name", "url": "url", "selector": "selector", "minutes": "minutes"]],
        ],
        [
            "name": "listWatches",
            "description": "List page watches (name/url/minutes/changeCount/enabled).",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/watches"],
        ],
        [
            "name": "checkWatch",
            "description": "Force a watch check now. Returns whether the content changed.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ],
            "_bridge": ["method": "POST", "path": "/watches/check", "body": ["name": "name"]],
        ],
        [
            "name": "removeWatch",
            "description": "Remove a page watch.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ],
            "_bridge": ["method": "POST", "path": "/watches/remove", "body": ["name": "name"]],
        ],
        [
            "name": "resolveBeforeUnload",
            "description": "Resolve a beforeunload guard that blocks navigation away from a form page (check /page/url or the beforeunloadPending event). leave=true discards and navigates; leave=false stays.",
            "inputSchema": [
                "type": "object",
                "properties": ["leave": ["type": "boolean"]],
                "required": ["leave"],
            ],
            "_bridge": ["method": "POST", "path": "/beforeunload/resolve", "body": ["leave": "leave"]],
        ],
        // 0.1.12 — media pipeline
        [
            "name": "listPageVideos",
            "description": "List media resources detected on a tab (network-sniffed CDN URLs behind blob: players + DOM/meta scan): video/audio/stream kinds with URLs.",
            "inputSchema": [
                "type": "object",
                "properties": ["index": ["type": "integer", "description": "Tab index; defaults to active"]],
            ],
            "_bridge": ["method": "GET", "path": "/media"],
        ],
        [
            "name": "downloadFile",
            "description": "Download a file from a direct URL into the Downloads folder (store-owned, pause/resume-capable). Fire-and-forget; poll listDownloads.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string"],
                    "filename": ["type": "string"],
                ],
                "required": ["url"],
            ],
            "_bridge": ["method": "POST", "path": "/downloads/start", "body": ["url": "url", "filename": "filename"]],
        ],
        [
            "name": "downloadMedia",
            "description": "Download a media resource (direct file OR HLS m3u8 with AES-128 decryption, using the page referer) into Downloads. Starts in the background; the file lands when finished. Pair with listPageVideos.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Media or m3u8 URL"],
                    "referer": ["type": "string", "description": "Page URL the media lives on (helps HLS authorization)"],
                    "filename": ["type": "string", "description": "Output name hint"],
                ],
                "required": ["url"],
            ],
            "_bridge": ["method": "POST", "path": "/media/download", "body": ["url": "url", "referer": "referer", "filename": "filename"]],
        ],
        // 0.2.7 — memory v2
        [
            "name": "searchMemory",
            "description": "Search the agent's long-term memory (facts about the user and their preferences). Pinned results first.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
            "_bridge": ["method": "POST", "path": "/memory/search", "body": ["query": "query"]],
        ],
        [
            "name": "rememberFact",
            "description": "Store a durable fact about the user or their preferences in the agent's long-term memory. Scope it to a domain (e.g. 'github.com') for site-specific facts.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "content": ["type": "string", "description": "The fact to remember"],
                    "category": ["type": "string", "description": "preference | habit | fact | correction"],
                    "scope": ["type": "string", "description": "global or a domain like 'github.com'"],
                ],
                "required": ["content"],
            ],
            "_bridge": ["method": "POST", "path": "/memory/facts/add", "body": ["content": "content", "category": "category", "scope": "scope"]],
        ],
        // 0.1.13 — network interception
        [
            "name": "addInterceptRule",
            "description": "Add a network interception rule: block or redirect requests matching a URL filter (WebKit url-filter syntax, substring + * wildcards). Applies to every webview immediately. Use for blocking trackers/CDNs in tests, redirecting endpoints to mirrors.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "urlFilter": ["type": "string", "description": "URL filter, e.g. '*analytics*' or '||tracker.example/'"],
                    "kind": ["type": "string", "description": "block | redirect"],
                    "payload": ["type": "string", "description": "Redirect target URL (redirect kind only)"],
                ],
                "required": ["urlFilter", "kind"],
            ],
            "_bridge": ["method": "POST", "path": "/intercept/add", "body": ["urlFilter": "urlFilter", "kind": "kind", "payload": "payload"]],
        ],
        [
            "name": "listInterceptRules",
            "description": "List interception rules (id/urlFilter/kind/payload/enabled).",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/intercept"],
        ],
        [
            "name": "clearInterceptRules",
            "description": "Remove ALL interception rules.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "POST", "path": "/intercept/clear", "body": []],
        ],
        // 0.1.14 — rule recording
        [
            "name": "recordInterceptRules",
            "description": "Turn OBSERVED network requests into block rules (from the DevTools network log). pattern filters URLs (case-insensitive substring); localhost infrastructure is excluded. Great for cutting third-party dependencies after first load.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "URL substring to match, e.g. 'analytics' or 'cdn.example'"],
                    "limit": ["type": "integer", "description": "Max rules to add (default 20)"],
                ],
                "required": ["pattern"],
            ],
            "_bridge": ["method": "POST", "path": "/intercept/record", "body": ["pattern": "pattern"]],
        ],
        // 0.1.14 — vision
        [
            "name": "fullPageScreenshot",
            "description": "Capture the ENTIRE scrollable page as a PDF (not just the viewport) → ~/desire_fullpage.pdf. Use for archiving/reading long pages; combine with downloadFile-style flows.",
            "inputSchema": [
                "type": "object",
                "properties": ["index": ["type": "integer"]],
            ],
            "_bridge": ["method": "POST", "path": "/screenshot/fullpage", "body": ["index": "index"]],
        ],
        // 0.1.11 — structured extraction
        [
            "name": "extractTables",
            "description": "Extract all HTML tables on the page as structured {headers, rows} JSON. A selector narrows to one table. Rows capped at 1000/table.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": ["type": "string", "description": "Optional selector of a specific <table>"],
                    "index": ["type": "integer", "description": "Tab index; defaults to active"],
                ],
            ],
            "_bridge": ["method": "POST", "path": "/extract", "const": ["kind": "table"], "body": ["selector": "selector", "index": "index"]],
        ],
        [
            "name": "extractTablesCSV",
            "description": "Same as extractTables but returns CSV text (headers + rows).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": ["type": "string"],
                    "index": ["type": "integer"],
                ],
            ],
            "_bridge": ["method": "POST", "path": "/extract", "const": ["kind": "table", "format": "csv"], "body": ["selector": "selector", "index": "index"]],
        ],
        [
            "name": "extractList",
            "description": "Extract list items as {text, href} JSON — selector picks the item elements; default is all ul/ol li.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "selector": ["type": "string", "description": "Selector of item elements"],
                    "index": ["type": "integer"],
                ],
            ],
            "_bridge": ["method": "POST", "path": "/extract", "const": ["kind": "list"], "body": ["selector": "selector", "index": "index"]],
        ],
    ]
}
