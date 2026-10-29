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
    private final class ConnectionContext {
        let sessionID = UUID().uuidString
        var windowID: String?
    }
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
        let value = header.split(separator: ":", maxSplits: 1).last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return BearerAuthentication.matches(header: value, token: requiredToken)
    }

    private static func passesOriginGuard(_ request: String) -> Bool {
        func isLocal(_ value: String, scheme: Bool) -> Bool {
            var raw = value
            if scheme, let separator = raw.range(of: "://") {
                raw = String(raw[separator.upperBound...])
            }
            let host = raw.split(separator: ":", maxSplits: 1).first?
                .lowercased() ?? raw.lowercased()
            return host == "127.0.0.1" || host == "localhost"
        }
        if let host = requestHeader(request, "Host"), !isLocal(host, scheme: false) {
            return false
        }
        if let origin = requestHeader(request, "Origin"),
           origin == "null" || !isLocal(origin, scheme: true) {
            return false
        }
        return true
    }

    private static func requestHeader(_ request: String, _ name: String) -> String? {
        request.split(separator: "\r\n", omittingEmptySubsequences: false)
            .first { $0.lowercased().hasPrefix("\(name.lowercased()):") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces)
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
        // 同 AutomationServer：专用队列，主 actor 死时 MCP 桥仍存活（CONC-1）。
        listener.start(queue: Self.bridgeQueue)
        Log.agent.info("mcp server ready on 127.0.0.1:\(Self.port)/mcp")
    }

    // MARK: - Connection handling

    private nonisolated static let bridgeQueue = DispatchQueue(label: "me.siwi.Desire.mcp-bridge")

    private func handle(_ connection: NWConnection) {
        connection.start(queue: Self.bridgeQueue)
        accumulate(connection, Data(), context: ConnectionContext())
    }

    /// Reads until a complete request is buffered. URLSession writes headers
    /// and body as SEPARATE TCP segments — a single receive returns headers
    /// only and produced "400 bad json" for every real MCP client.
    private func accumulate(_ connection: NWConnection, _ buffer: Data, context: ConnectionContext) {
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
                        let request = String(data: accumulated, encoding: .utf8) ?? ""
                        if Self.passesOriginGuard(request), Self.isAuthorized(request) {
                            self.handleComplete(connection, accumulated, context: context)
                        } else {
                            let status = Self.passesOriginGuard(request) ? "401 Unauthorized" : "403 Forbidden"
                            let message = Self.passesOriginGuard(request)
                                ? "unauthorized — missing or wrong bearer token"
                                : "forbidden — MCP only accepts local Host/Origin"
                            self.respond(connection, status: status, body: "{\"error\":\"\(message)\"}")
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
                self.accumulate(connection, accumulated, context: context)
            }
        }
    }

    private func handleComplete(_ connection: NWConnection, _ buffer: Data, context: ConnectionContext) {
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
            let (status, body, _) = await self.dispatch(rpc, context: context)
            self.respond(connection, status: status, body: body,
                         extraHeaders: "Mcp-Session-Id: \(context.sessionID)\r\n")
        }
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

    private func dispatch(_ rpc: [String: Any], context: ConnectionContext) async -> (status: String, body: String, isNotification: Bool) {
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
            context.windowID = windowID
        }

        // Notifications get 202 Accepted, no body.
        if isNotification {
            return ("202 Accepted", "", true)
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2025-06-18",
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": [:],
                    "prompts": [:],
                ],
                "serverInfo": ["name": "Desire", "version": Self.serverVersion],
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
            if let boundWindow = context.windowID, args["window"] == nil {
                args["window"] = boundWindow
            }
            // 复合工具：askAgent = 发消息 + 轮询回合结束 + 返回回复（不是单一桥端点）。
            if name == "askAgent" {
                return await Self.handleAskAgent(id: id, args: args, window: context.windowID)
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
            let targetWindow = args["window"] as? String ?? context.windowID
            let bridgeResponse = await AutomationServer.shared.callEndpoint(
                method: httpMethod, path: path, json: payload.isEmpty ? nil : payload,
                window: targetWindow
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

        case "resources/list":
            return await resourcesList(id: id, windowID: context.windowID)

        case "resources/read":
            return await resourcesRead(id: id, uri: params["uri"] as? String ?? "", windowID: context.windowID)

        case "prompts/list":
            return ("200 OK", Self.rpcResult(id: id, result: ["prompts": Self.promptCatalog.map { prompt in
                prompt.filter { !$0.key.hasPrefix("_") }
            }]), false)

        case "prompts/get":
            return promptsGet(id: id, name: params["name"] as? String ?? "",
                              args: params["arguments"] as? [String: String] ?? [:])

        default:
            return ("200 OK", Self.rpcError(id: id, code: -32601, message: "method not found: \(method)"), false)
        }
    }

    // MARK: - MCP resources (page://<tab>/<kind>)

    /// Every open tab as three resources: page://<index>/text|html|screenshot.
    private func resourcesList(id: Any?, windowID: String?) async -> (status: String, body: String, isNotification: Bool) {
        let stateResponse = await AutomationServer.shared.callEndpoint(
            method: "GET", path: "/state", json: nil, window: windowID
        )
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(stateResponse.utf8)) as? [String: Any],
              let tabs = parsed["tabs"] as? [[String: Any]] else {
            return ("200 OK", Self.rpcError(id: id, code: -32603, message: "cannot enumerate tabs"), false)
        }
        var resources: [[String: Any]] = []
        for tab in tabs {
            let index = tab["index"] as? Int ?? 0
            let title = tab["title"] as? String ?? "tab \(index)"
            let url = tab["url"] as? String ?? ""
            let label = "Tab \(index): \(title)"
            resources.append([
                "uri": "page://\(index)/text",
                "name": "\(label) — text",
                "description": "Visible text of \(url)",
                "mimeType": "text/plain",
            ])
            resources.append([
                "uri": "page://\(index)/html",
                "name": "\(label) — html",
                "description": "Full DOM HTML of \(url)",
                "mimeType": "text/html",
            ])
            resources.append([
                "uri": "page://\(index)/screenshot",
                "name": "\(label) — screenshot",
                "description": "Viewport PNG of \(url)",
                "mimeType": "image/png",
            ])
        }
        return ("200 OK", Self.rpcResult(id: id, result: ["resources": resources]), false)
    }

    private func resourcesRead(id: Any?, uri: String, windowID: String?) async -> (status: String, body: String, isNotification: Bool) {
        guard let url = URL(string: uri), url.scheme == "page",
              let index = Int(url.host ?? ""),
              url.path.count > 1 else {
            return ("200 OK", Self.rpcError(id: id, code: -32602, message: "invalid resource URI (expected page://<tab>/<text|html|screenshot>)"), false)
        }
        let kind = String(url.path.dropFirst())
        func contents(_ payload: [[String: Any]]) -> String {
            Self.rpcResult(id: id, result: ["contents": payload])
        }

        switch kind {
        case "text":
            let response = await AutomationServer.shared.callEndpoint(
                method: "GET", path: "/page/text?index=\(index)", json: nil, window: windowID
            )
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  let text = parsed["text"] as? String else {
                return ("200 OK", Self.rpcError(id: id, code: -32603, message: "cannot read text of tab \(index)"), false)
            }
            return ("200 OK", contents([["uri": uri, "mimeType": "text/plain", "text": text]]), false)

        case "html":
            let response = await AutomationServer.shared.callEndpoint(
                method: "POST", path: "/execute",
                json: ["js": "document.documentElement.outerHTML", "index": index],
                window: windowID
            )
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  let html = parsed["result"] as? String else {
                return ("200 OK", Self.rpcError(id: id, code: -32603, message: "cannot read html of tab \(index)"), false)
            }
            return ("200 OK", contents([["uri": uri, "mimeType": "text/html", "text": html]]), false)

        case "screenshot":
            let response = await AutomationServer.shared.callEndpoint(
                method: "GET", path: "/screenshot?index=\(index)&inline=1", json: nil, window: windowID
            )
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
                  let base64 = parsed["base64"] as? String else {
                return ("200 OK", Self.rpcError(id: id, code: -32603, message: "cannot read screenshot of tab \(index)"), false)
            }
            return ("200 OK", contents([["uri": uri, "mimeType": "image/png", "blob": base64]]), false)

        default:
            return ("200 OK", Self.rpcError(id: id, code: -32602, message: "unknown resource kind: \(kind)"), false)
        }
    }

    // MARK: - MCP prompts

    /// Reusable task templates. `_template` is rendered by prompts/get:
    /// `{argument}` placeholders substitute provided values; unknown ones
    /// resolve to "" (the surrounding sentence stays readable).
    private static let promptCatalog: [[String: Any]] = [
        [
            "name": "summarize-page",
            "description": "Summarize the current page: topic, key points, notable media.",
            "arguments": [],
            "_template": "Use the getPageText tool to read the current page, then write a concise summary in the user's language: the main topic, up to five key points, and any notable links, media, or download-worthy assets.",
        ],
        [
            "name": "extract-data",
            "description": "Extract structured data from the current page as JSON/CSV.",
            "arguments": [["name": "target", "description": "What to extract, e.g. \"all product prices\"", "required": false]],
            "_template": "Extract {target} from the current page. Try the extractTables or extractList tools first; fall back to getPageText plus careful parsing. Return clean JSON (or CSV on request) and say if the page paginates and data looks truncated.",
        ],
        [
            "name": "monitor-page",
            "description": "Set up change monitoring for the current tab.",
            "arguments": [["name": "interval", "description": "Polling interval in minutes (default 5)", "required": false]],
            "_template": "Set up change monitoring for the current tab with the watchPage tool, polling every {interval} minutes. Tell me what exactly will be watched (content fingerprint or selector), and how I will be notified when it changes.",
        ],
        [
            "name": "download-media",
            "description": "Find and download media from the current page.",
            "arguments": [["name": "quality", "description": "Preferred quality, e.g. \"highest bandwidth\"", "required": false]],
            "_template": "Find media on the current page: run listPageVideos, and listMediaVariants for HLS streams. Pick the {quality} match, download it with downloadMedia, then report the saved filename and size.",
        ],
    ]

    private func promptsGet(id: Any?, name: String, args: [String: String]) -> (status: String, body: String, isNotification: Bool) {
        guard let prompt = Self.promptCatalog.first(where: { $0["name"] as? String == name }),
              let template = prompt["_template"] as? String else {
            return ("200 OK", Self.rpcError(id: id, code: -32602, message: "unknown prompt \(name)"), false)
        }
        var text = template
        for (field, value) in args {
            text = text.replacingOccurrences(of: "{\(field)}", with: value)
        }
        // Unfilled optional arguments: drop the braces, keep a sane default.
        text = text.replacingOccurrences(of: #"\{[a-zA-Z]+\}"#, with: "", options: .regularExpression)
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": ["type": "text", "text": text],
        ]]
        let description = prompt["description"] as? String ?? ""
        return ("200 OK", Self.rpcResult(id: id, result: ["description": description, "messages": messages]), false)
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
                // 第十批：.urlQueryAllowed 含 & = + ? #——参数值里的这些字符
                // 会改写 query 结构（findInPage 的 q=a&index=2 注入第二个参数）。
                // 从 allowed 集合里剔除。
                let allowed = CharacterSet.urlQueryAllowed
                    .subtracting(CharacterSet(charactersIn: "&=#+?"))
                rendered = scalar.addingPercentEncoding(withAllowedCharacters: allowed) ?? scalar
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

    /// 对外报告的版本（原来是硬编码的 0.2.12）。
    private static var serverVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// `askAgent`：发一条消息 → 轮询回合结束 → 返回助手回复与新增消息。
    ///
    /// 时序处理：send 是异步入队，busy 可能晚于第一次轮询才置起——所以
    /// 结束判据是「(观测到 busy 之后又空闲) 或 (空闲且出现新消息)」，
    /// 仅在两者都没有时继续等（宽限到超时）。
    private static func handleAskAgent(id: Any?, args: [String: Any],
                                       window: String?) async -> (String, String, Bool) {
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ("200 OK", Self.rpcError(id: id, code: -32602, message: "text is required"), false)
        }
        let wait = (args["wait"] as? Bool) ?? true
        let timeout = min(600, max(10, (args["timeoutSeconds"] as? Int) ?? 180))
        let targetWindow = (args["window"] as? String) ?? window

        func snapshot() async -> [String: Any]? {
            let raw = await AutomationServer.shared.callEndpoint(
                method: "GET", path: "/agent/messages", json: nil, window: targetWindow)
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        }

        guard let before = await snapshot() else {
            return ("200 OK", Self.rpcError(id: id, code: -32603, message: "agent messages unavailable"), false)
        }
        if before["error"] != nil {
            return ("200 OK", Self.rpcResult(id: id, result: [
                "content": [["type": "text", "text": "No live agent session — open a Desire window with the Agent panel first."]],
                "isError": true,
            ]), false)
        }
        if (before["busy"] as? Bool) == true {
            return ("200 OK", Self.rpcResult(id: id, result: [
                "content": [["type": "text", "text": "Agent is busy with another turn. Retry later, or read getAgentMessages while it works."]],
                "isError": true,
            ]), false)
        }
        let beforeIDs = Set(((before["messages"] as? [[String: Any]]) ?? [])
            .compactMap { $0["id"] as? String })

        let sendRaw = await AutomationServer.shared.callEndpoint(
            method: "POST", path: "/agent/send",
            json: ["text": text, "recordHistory": false], window: targetWindow)
        if let sent = (try? JSONSerialization.jsonObject(with: Data(sendRaw.utf8))) as? [String: Any],
           let error = sent["error"] as? String {
            return ("200 OK", Self.rpcResult(id: id, result: [
                "content": [["type": "text", "text": "send failed: \(error)"]],
                "isError": true,
            ]), false)
        }
        guard wait else {
            return ("200 OK", Self.rpcResult(id: id, result: [
                "content": [["type": "text", "text": "Prompt sent. Poll getAgentMessages / getAgentTrace for the reply."]],
                "isError": false,
            ]), false)
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var sawBusy = false
        var latest: [String: Any] = before
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let current = await snapshot() else { continue }
            latest = current
            let busy = (current["busy"] as? Bool) ?? false
            let ids = Set(((current["messages"] as? [[String: Any]]) ?? [])
                .compactMap { $0["id"] as? String })
            let hasNew = !ids.subtracting(beforeIDs).isEmpty
            if busy {
                sawBusy = true
                continue
            }
            if sawBusy || hasNew { break }
        }

        let messages = (latest["messages"] as? [[String: Any]]) ?? []
        let newOnes = messages.filter { message in
            guard let messageID = message["id"] as? String else { return false }
            return !beforeIDs.contains(messageID)
        }
        let assistant = newOnes.last { message in
            (message["role"] as? String) == "assistant"
                && ((message["content"] as? String) ?? "").isEmpty == false
        }
        let reply = (assistant?["content"] as? String) ?? ""
        let timedOut = (latest["busy"] as? Bool) == true
        var summary: [String: Any] = [
            "reply": reply,
            "busy": latest["busy"] ?? false,
            "timedOut": timedOut,
            "hasInterruptedTurn": latest["hasInterruptedTurn"] ?? false,
            "newMessages": newOnes.map { message -> [String: Any] in
                var item: [String: Any] = ["role": message["role"] ?? ""]
                if let content = message["content"] as? String, !content.isEmpty {
                    item["content"] = String(content.prefix(4_000))
                }
                if let calls = message["toolCalls"] { item["toolCalls"] = calls }
                return item
            },
        ]
        if reply.isEmpty, !timedOut {
            summary["note"] = "No assistant reply yet — call getAgentMessages / getAgentTrace."
        }
        if timedOut {
            summary["note"] = "Timed out after \(timeout)s; the turn is still running. Read getAgentMessages/getAgentTrace."
        }
        let textOut = (try? JSONSerialization.data(withJSONObject: summary,
                                                   options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ("200 OK", Self.rpcResult(id: id, result: [
            "content": [["type": "text", "text": textOut]],
            "isError": false,
        ]), false)
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
            "name": "crewDispatch",
            "description": "Dispatch a crew: 2-6 subtasks, each worked on its own tab by a read-only worker agent; reports aggregate in the leader session.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "objective": ["type": "string", "description": "Short task name"],
                    "tasks": ["type": "array", "description": "2-6 subtasks", "items": ["type": "object", "properties": [
                        "url": ["type": "string"],
                        "instruction": ["type": "string"],
                    ]]],
                ],
                "required": ["objective", "tasks"],
            ],
            "_bridge": ["method": "POST", "path": "/agent/crew-dispatch", "body": ["objective": "objective", "tasks": "tasks"]],
        ],
        [
            "name": "crewStatus",
            "description": "Per-subtask progress and finished reports of the crew.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/agent/crew"],
        ],
        [
            "name": "crewCancel",
            "description": "Cancel the crew (or one subtask by index).",
            "inputSchema": [
                "type": "object",
                "properties": ["index": ["type": "number"]],
            ],
            "_bridge": ["method": "POST", "path": "/agent/crew/cancel", "body": ["index": "index"]],
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
        // 0.2.8 — media pipeline v2
        [
            "name": "listMediaVariants",
            "description": "List available quality variants of an HLS master playlist (bandwidth + resolution for each). Use before downloadMedia when the user wants a specific quality.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Master m3u8 playlist URL"],
                    "referer": ["type": "string"],
                ],
                "required": ["url"],
            ],
            "_bridge": ["method": "GET", "path": "/media/variants", "body": ["url": "url", "referer": "referer"]],
        ],
        [
            "name": "batchDownload",
            "description": "Start multiple downloads at once. Each URL is queued as a store-owned download with pause/resume support.",
            "inputSchema": [
                "type": "object",
                "properties": ["urls": ["type": "array", "items": ["type": "string"], "description": "Direct download URLs"]],
                "required": ["urls"],
            ],
            "_bridge": ["method": "POST", "path": "/downloads/batch", "body": ["urls": "urls"]],
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
        // 0.8.22 — Agent 对话与自省面（外部编程工具 ↔ 浏览器 Agent）
        [
            "name": "askAgent",
            "description": "Send a prompt to the live Desire agent (the chat agent that can browse and use its own tools) and wait for its reply. This is the two-way channel: the coding tool asks, the browser agent acts and answers. Returns JSON {reply, busy, timedOut, newMessages}. Follow up with getAgentTrace to inspect every step/tool call it made.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "Prompt for the browser agent"],
                    "wait": ["type": "boolean", "description": "Wait for the turn to finish (default true)"],
                    "timeoutSeconds": ["type": "integer", "description": "Max wait in seconds (default 180, max 600)"],
                    "window": ["type": "string", "description": "Target window id (usually omit — the live session is used)"],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "getAgentMessages",
            "description": "Read the live agent conversation: last messages (role/content/toolCalls/model/tokens) plus busy and hasInterruptedTurn.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/agent/messages"],
        ],
        [
            "name": "getAgentTrace",
            "description": "Derived per-turn trace as JSONL: goal, steps (tool, args, observation, duration, denied/threwError), answer, critique, verification note, user feedback. Best tool for diagnosing why the agent failed and for building eval fixtures.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "conversation": ["type": "string", "description": "Conversation UUID (default: live)"],
                    "limit": ["type": "integer", "description": "Max turns (default all, newest last)"],
                ],
            ],
            "_bridge": ["method": "GET", "path": "/agent/trace?conversation={conversation}&limit={limit}"],
        ],
        [
            "name": "getAgentStats",
            "description": "Usage statistics derived from saved conversations: totals, peaks, daily and per-model breakdown, streak.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/agent/stats"],
        ],
        [
            "name": "getAgentCost",
            "description": "Cost breakdown for the live conversation (tokens × user-configured prices; unpriced models show tokens only).",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/agent/cost-breakdown"],
        ],
        [
            "name": "getAgentBudget",
            "description": "Conversation token budget state (budget/used/state/stopLevel/percent). Set it with setAgentBudget.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/agent/budget"],
        ],
        [
            "name": "setAgentBudget",
            "description": "Set the conversation token budget (0 turns it off).",
            "inputSchema": [
                "type": "object",
                "properties": ["tokens": ["type": "integer", "description": "0 = off"]],
                "required": ["tokens"],
            ],
            "_bridge": ["method": "POST", "path": "/agent/budget", "body": ["tokens": "tokens"]],
        ],
        [
            "name": "getAgentDoctor",
            "description": "Agent self-check: model endpoint reachability, keys, MCP connections, ffmpeg, hooks, skills, notifications, heartbeat.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/agent/doctor"],
        ],
        [
            "name": "addAgentNote",
            "description": "Append a system note to the live conversation (not rendered in the chat; folded into the next turn's system prompt). Use it to hand observations from your coding tool to the browser agent.",
            "inputSchema": [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "required": ["text"],
            ],
            "_bridge": ["method": "POST", "path": "/agent/note", "body": ["text": "text"]],
        ],
        [
            "name": "setAgentDirective",
            "description": "Set or clear the session-scoped instruction (e.g. answer in English, be terse); empty text clears it.",
            "inputSchema": [
                "type": "object",
                "properties": ["text": ["type": "string"]],
                "required": ["text"],
            ],
            "_bridge": ["method": "POST", "path": "/agent/directive", "body": ["text": "text"]],
        ],
        [
            "name": "rateAgentMessage",
            "description": "Rate an assistant message (thumbs up/down/none). Ratings persist with the conversation and drive exportEval.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "messageId": ["type": "string", "description": "Message id from getAgentMessages"],
                    "vote": ["type": "string", "description": "up | down | none"],
                ],
                "required": ["messageId", "vote"],
            ],
            "_bridge": ["method": "POST", "path": "/agent/feedback", "body": ["messageId": "messageId", "vote": "vote"]],
        ],
        [
            "name": "searchConversations",
            "description": "Search saved conversations by title/message text (mode=literal) or by meaning (mode=semantic — requires Agent Conversations enabled under Settings › Search & Index).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer"],
                    "mode": ["type": "string", "description": "literal | semantic"],
                ],
                "required": ["query"],
            ],
            "_bridge": ["method": "GET", "path": "/conversations/search?q={query}&limit={limit}&mode={mode}"],
        ],
        [
            "name": "semanticSearch",
            "description": "On-device semantic search across history pages, bookmarks, excerpts and reading highlights (same-language shard; literal search remains primary in the app).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer", "description": "Default 20"],
                    "source": ["type": "string", "description": "history | bookmark | excerpt | highlight | conversation"],
                ],
                "required": ["query"],
            ],
            "_bridge": ["method": "GET", "path": "/search/semantic?q={query}&limit={limit}&source={source}"],
        ],
        [
            "name": "exportEval",
            "description": "Export 👍-rated turns as an eval JSONL (AgentTrace-derived) — the fixture source for agent-eval regression runs.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Target directory (default: agent workspace exports)"]],
            ],
            "_bridge": ["method": "POST", "path": "/agent/eval-export", "body": ["path": "path"]],
        ],
        [
            "name": "getAgentReport",
            "description": "Per-turn WORK REPORT for a conversation (derived from saved messages): goal, outcome (success/partial/failed), steps, tool usage counts, failures with the exact Error text, self-critique, verification note and the final answer. This is the fastest way for a coding tool to see how the browser agent worked and where it struggled.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "conversation": ["type": "string", "description": "Conversation UUID (default: live)"],
                    "limit": ["type": "integer", "description": "Max turns (default 20, max 50)"],
                ],
            ],
            "_bridge": ["method": "GET", "path": "/agent/report?conversation={conversation}&limit={limit}"],
        ],
        [
            "name": "getAgentGaps",
            "description": "Capability gaps the browser agent reported itself (missing tools/features), ranked by how often they blocked it — with the workaround it used and the page/context. Consume this to decide which capability to build next.",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "GET", "path": "/agent/gaps"],
        ],
        [
            "name": "reportCapabilityGap",
            "description": "Record a capability gap found by YOUR tooling (same store the agent's own reportCapabilityGap tool writes). Use it when you observe a missing capability while driving the browser through Desire.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "capability": ["type": "string", "description": "Missing capability/tool, short noun phrase"],
                    "blocked": ["type": "string"],
                    "workaround": ["type": "string"],
                    "severity": ["type": "string", "description": "blocker | friction | nice-to-have"],
                    "context": ["type": "string"],
                ],
                "required": ["capability"],
            ],
            "_bridge": ["method": "POST", "path": "/agent/gaps", "body": ["capability": "capability", "blocked": "blocked", "workaround": "workaround", "severity": "severity", "context": "context"]],
        ],
        [
            "name": "clearAgentGaps",
            "description": "Clear the recorded capability gaps (after you have filed them upstream).",
            "inputSchema": ["type": "object", "properties": [:]],
            "_bridge": ["method": "POST", "path": "/agent/gaps/clear"],
        ],
        [
            "name": "exportWorkReport",
            "description": "Write a Markdown work report for the live conversation (per-turn facts + capability-gap table) into the agent workspace (or a directory you pass). Returns the path — read it directly from your coding environment.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "Target directory (default: agent workspace)"]],
            ],
            "_bridge": ["method": "POST", "path": "/agent/report/export", "body": ["path": "path"]],
        ],
        [
            "name": "weeklyKnowledgeDigest",
            "description": "Cluster this week's excerpts (web selections / PDF annotations / reading highlights) into themes on-device and write a Markdown digest into the agent workspace. Deterministic: embeddings + greedy clustering, no model call.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "Window in days (default 7, max 365)"],
                    "path": ["type": "string", "description": "Target directory (default: agent workspace)"],
                ],
            ],
            "_bridge": ["method": "POST", "path": "/knowledge/weekly", "body": ["days": "days", "path": "path"]],
        ],
    ]
}
