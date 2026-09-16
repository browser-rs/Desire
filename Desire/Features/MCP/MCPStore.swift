import Combine
import Foundation
import os

/// Registry + bridge for MCP servers: config persistence, connections,
/// and the mapping MCP tools <-> Desire's `AgentToolDef` tool schema.
///
/// Bridged tool names are `mcp_<server>_<tool>` (sanitized, lowercased) so
/// they can ride the same OpenAI-style tool-calling path as built-ins and
/// inherit the same approval gating (unknown tools classify as sideEffect).
@MainActor
class MCPStore: ObservableObject {
    static let shared = MCPStore()

    @Published private(set) var servers: [MCPServer] = []
    /// Tool definitions offered to the agent (enabled + connected servers).
    @Published private(set) var toolDefs: [AgentToolDef] = []
    /// Human-readable per-server status for the settings UI.
    @Published private(set) var statuses: [UUID: String] = [:]

    private var connections: [UUID: MCPConnection] = [:]
    /// defName -> (server id, raw tool name on that server).
    private var toolRoutes: [String: (serverID: UUID, toolName: String)] = [:]
    private var cachedTools: [UUID: [MCPTool]] = [:]
    private let storageKey = "mcp-servers"

    private init() {
        servers = DiskStore.load([MCPServer].self, key: storageKey) ?? []
        for server in servers where server.isEnabled {
            Task { await connect(server) }
        }
    }

    // MARK: - Configuration

    func addServer(name: String, url: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let _ = URL(string: trimmedURL), trimmedURL.hasPrefix("http") else { return }
        let server = MCPServer(id: UUID(), name: trimmedName, url: trimmedURL)
        servers.append(server)
        save()
        if server.isEnabled {
            Task { await connect(server) }
        }
    }

    func removeServer(_ id: UUID) {
        servers.removeAll { $0.id == id }
        connections[id] = nil
        cachedTools[id] = nil
        rebuildTools()
        save()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].isEnabled = enabled
        save()
        if enabled {
            Task { await connect(servers[i]) }
        } else {
            connections[id] = nil
            statuses[id] = "disabled"
            rebuildTools()
        }
    }

    func reconnect(_ id: UUID) {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        Task { await connect(server) }
    }

    private func save() {
        DiskStore.save(servers, key: storageKey)
    }

    // MARK: - Connection + bridging

    func connect(_ server: MCPServer) async {
        guard server.isEnabled, let endpoint = URL(string: server.url) else { return }
        statuses[server.id] = "connecting…"
        var connection = MCPConnection(endpoint: endpoint)
        do {
            let tools = try await connection.connect()
            connections[server.id] = connection
            cachedTools[server.id] = tools
            statuses[server.id] = "ready · \(tools.count) tools"
            rebuildTools()
            Log.ai.info("MCP server \(server.name, privacy: .public) connected — \(tools.count) tools")
        } catch {
            connections[server.id] = nil
            cachedTools[server.id] = nil
            statuses[server.id] = "failed: \(error.localizedDescription)"
            rebuildTools()
            Log.ai.error("MCP server \(server.name, privacy: .public) failed: \(error.localizedDescription)")
        }
    }

    private func rebuildTools() {
        var defs: [AgentToolDef] = []
        var routes: [String: (serverID: UUID, toolName: String)] = [:]
        for server in servers where server.isEnabled {
            guard connections[server.id] != nil else { continue }
            for tool in cachedTools[server.id] ?? [] {
                let defName = Self.bridgedToolName(server: server.name, tool: tool.name)
                guard routes[defName] == nil else { continue }
                routes[defName] = (server.id, tool.name)
                defs.append(AgentToolDef(
                    type: "function",
                    function: AgentToolFunctionDef(
                        name: defName,
                        description: Self.bridgedDescription(server: server, tool: tool),
                        parameters: Self.parametersSchema(for: tool)
                    )
                ))
            }
        }
        toolDefs = defs
        toolRoutes = routes
    }

    /// `mcp_<server>_<tool>`, lowercased and sanitized to the tool-name
    /// charset OpenAI-style APIs accept.
    private static func bridgedToolName(server: String, tool: String) -> String {
        func sanitize(_ s: String) -> String {
            String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        }
        return "mcp_\(sanitize(server))_\(sanitize(tool))"
    }

    private static func bridgedDescription(server: MCPServer, tool: MCPTool) -> String {
        var text = "[MCP · \(server.name)] "
        text += tool.description.isEmpty ? tool.name : tool.description
        // The schema passed to the model is depth-limited by our Codable
        // shape — carry the RAW schema in the description so enum/items
        // constraints still reach the model.
        text += "\nArguments JSON schema: \(tool.inputSchemaJSON.prefix(800))"
        return text
    }

    private static func parametersSchema(for tool: MCPTool) -> AgentJSONSchema {
        if let data = tool.inputSchemaJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AgentJSONSchema.self, from: data) {
            return decoded
        }
        return AgentJSONSchema(type: "object", properties: [:])
    }

    /// Executes an agent tool call bridged to an MCP server.
    func callTool(defName: String, argumentsJSON: String) async -> String {
        guard let route = toolRoutes[defName], var connection = connections[route.serverID] else {
            return "MCP tool unavailable — server disconnected"
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        do {
            let text = try await connection.callTool(named: route.toolName, arguments: arguments)
            connections[route.serverID] = connection
            return text
        } catch {
            connections[route.serverID] = connection
            return "MCP tool error: \(error.localizedDescription)"
        }
    }
}
