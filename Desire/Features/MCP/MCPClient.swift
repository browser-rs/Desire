import Foundation

/// One tool exposed by an MCP server, converted into Desire's tool schema.
struct MCPTool {
    let name: String
    let description: String
    let inputSchemaJSON: String
}

/// Minimal JSON-RPC error surfaced to callers with its server-side message.
enum MCPError: LocalizedError {
    case badResponse
    case http(Int, String)
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Malformed MCP response"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .rpc(let message): return message
        }
    }
}

/// JSON-RPC client for one MCP server over the Streamable HTTP transport
/// (POST JSON-RPC to the endpoint; responses arrive as application/json or
/// as an SSE stream of `data:` lines). Tracks the `Mcp-Session-Id` header.
struct MCPConnection {
    let endpoint: URL
    let authToken: String?
    private(set) var sessionID: String?
    private var nextRequestID = 1

    /// Handshake: initialize → notifications/initialized → tools/list.
    mutating func connect() async throws -> [MCPTool] {
        _ = try await post(
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Desire", "version": "0.1"],
            ],
            notification: false
        )
        _ = try? await post(method: "notifications/initialized", params: nil, notification: true)
        let listResponse = try await post(method: "tools/list", params: [String: Any](), notification: false)
        guard let result = listResponse.resultObject else { throw MCPError.badResponse }
        let toolsJSON = result["tools"] as? [[String: Any]] ?? []
        return toolsJSON.compactMap(Self.tool(fromJSON:))
    }

    mutating func callTool(named name: String, arguments: [String: Any]) async throws -> String {
        let response = try await post(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            notification: false
        )
        guard let result = response.resultObject else { throw MCPError.badResponse }
        if (result["isError"] as? Bool) == true {
            let text = Self.text(fromContent: result["content"])
            throw MCPError.rpc(text.isEmpty ? "Tool reported an error" : text)
        }
        let text = Self.text(fromContent: result["content"])
        return text.isEmpty ? "(empty result)" : text
    }

    // MARK: - Transport

    private struct Response {
        let resultObject: [String: Any]?
    }

    private mutating func post(method: String, params: [String: Any]?, notification: Bool) async throws -> Response {
        nextRequestID += 1
        let id = nextRequestID
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { body["params"] = params }
        if !notification { body["id"] = id }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id"), sessionID == nil {
            sessionID = session
        }
        guard (200...299).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        if notification { return Response(resultObject: nil) }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var payload: [String: Any]?
        if contentType.contains("text/event-stream") {
            // SSE: responses arrive as `data: {json}` lines; pick the one
            // carrying our request id.
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(whereSeparator: \.isNewline).reversed() {
                guard line.hasPrefix("data:") else { continue }
                let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let obj = try? JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [String: Any],
                   obj["id"] as? Int == id {
                    payload = obj
                    break
                }
            }
        } else {
            payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let payloadObject = payload else { throw MCPError.badResponse }
        if let error = payloadObject["error"] as? [String: Any] {
            throw MCPError.rpc((error["message"] as? String) ?? "MCP error")
        }
        return Response(resultObject: payloadObject["result"] as? [String: Any])
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: - Parsing

    private static func tool(fromJSON json: [String: Any]) -> MCPTool? {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        let description = (json["description"] as? String) ?? ""
        var inputSchemaJSON = "{}"
        if let schema = json["inputSchema"],
           let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
            inputSchemaJSON = String(data: data, encoding: .utf8) ?? "{}"
        }
        return MCPTool(name: name, description: description, inputSchemaJSON: inputSchemaJSON)
    }

    private static func text(fromContent content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
