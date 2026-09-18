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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            // Complete when headers are parsed and body bytes match
            // Content-Length (or the peer half-closed with data buffered).
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let declared = headerText
                    .split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }?
                    .split(separator: ":").last
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                let bodyCount = buffer.count - headerEnd.upperBound
                if bodyCount >= declared {
                    Task { @MainActor in
                        self.handleComplete(connection, buffer)
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
            accumulate(connection, buffer)
        }
    }

    private func handleComplete(_ connection: NWConnection, _ buffer: Data) {
        guard let raw = String(data: buffer, encoding: .utf8) else {
            respond(connection, status: "400 Bad Request", body: #"{"error":"bad encoding"}"#)
            return
        }
        if raw.hasPrefix("GET ") {
            // Server→client streaming is not supported in v1.
            respond(connection, status: "405 Method Not Allowed", body: #"{"error":"GET not supported"}"#)
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

    // MARK: - JSON-RPC dispatch

    private func dispatch(_ rpc: [String: Any]) async -> (status: String, body: String, isNotification: Bool) {
        let method = rpc["method"] as? String ?? ""
        let id: Any? = rpc["id"]
        let isNotification = (id == nil)
        let params = rpc["params"] as? [String: Any] ?? [:]

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
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = Self.toolCatalog.first(where: { $0["name"] as? String == name }),
                  let mapping = tool["_bridge"] as? [String: Any] else {
                return ("200 OK", Self.rpcError(id: id, code: -32602, message: "unknown tool \(name)"), false)
            }
            let httpMethod = mapping["method"] as? String ?? "GET"
            let path = Self.resolvePath(mapping["path"] as? String ?? "", args)
            // Body fields map as {"<bridge field>": "<args field>"}.
            var payload: [String: Any] = [:]
            for (bridgeField, argsField) in (mapping["body"] as? [String: String]) ?? [String: String]() {
                if let value = args[argsField] {
                    payload[bridgeField] = value
                }
            }
            let bridgeResponse = await AutomationServer.shared.callEndpoint(
                method: httpMethod, path: path, json: payload.isEmpty ? nil : payload
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
    ]
}
