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
    /// stdio 传输的连接（子进程生命周期归 store 管）。
    private var stdioConnections: [UUID: MCPStdioConnection] = [:]
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

    /// stdio 服务器：command 为空格分隔 argv（带引号的段作整体）。
    func addStdioServer(name: String, command: String, envPairs: [String: String] = [:]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let argv = Self.parseArgv(command)
        guard !trimmedName.isEmpty, let executable = argv.first, !executable.isEmpty else { return }
        let server = MCPServer(id: UUID(), name: trimmedName, url: "",
                               isEnabled: true, transport: "stdio",
                               command: argv,
                               env: envPairs.isEmpty ? nil : envPairs)
        servers.append(server)
        save()
        Task { await connect(server) }
    }

    /// 空格分隔 argv 解析：双/单引号段作整体（python3 "/tmp/a b/s.py" → 两段）。
    static func parseArgv(_ raw: String) -> [String] {
        var argv: [String] = []
        var current = ""
        var quote: Character? = nil
        var hasToken = false
        for ch in raw {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                hasToken = true
            } else if ch == " " || ch == "\t" {
                if hasToken || !current.isEmpty {
                    argv.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(ch)
            }
        }
        if hasToken || !current.isEmpty { argv.append(current) }
        return argv
    }

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
        stdioConnections[id]?.terminate()
        stdioConnections[id] = nil
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
            stdioConnections[id]?.terminate()
            stdioConnections[id] = nil
            statuses[id] = "disabled"
            rebuildTools()
        }
    }

    /// Raw tool names exposed by a connected server (settings disclosure).
    func toolNames(for id: UUID) -> [String] {
        (cachedTools[id] ?? []).map(\.name)
    }

    func updateAuthToken(_ token: String, for id: UUID) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[idx].authToken = token.isEmpty ? nil : token
        save()
        if servers[idx].isEnabled { Task { await connect(servers[idx]) } }
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
        guard server.isEnabled else { return }
        if server.isStdio {
            await connectStdio(server)
            return
        }
        guard let endpoint = URL(string: server.url) else { return }
        statuses[server.id] = "connecting…"
        var connection = MCPConnection(endpoint: endpoint, authToken: server.authToken)
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

    private func connectStdio(_ server: MCPServer) async {
        let argv = server.command ?? []
        guard !argv.isEmpty else {
            statuses[server.id] = "failed: empty command"
            return
        }
        statuses[server.id] = "spawning…"
        stdioConnections[server.id]?.terminate()
        stdioConnections[server.id] = nil
        do {
            let connection = try MCPStdioConnection(serverName: server.name, argv: argv, env: server.env)
            let tools = try await connection.connect()
            stdioConnections[server.id] = connection
            cachedTools[server.id] = tools
            statuses[server.id] = "ready · \(tools.count) tools"
            rebuildTools()
            Log.ai.info("stdio MCP server \(server.name, privacy: .public) connected — \(tools.count, privacy: .public) tools")
        } catch {
            stdioConnections[server.id]?.terminate()
            stdioConnections[server.id] = nil
            cachedTools[server.id] = nil
            let stderr = (try? MCPStdioConnection(serverName: server.name, argv: argv, env: server.env))?.lastStderr ?? ""
            statuses[server.id] = "failed: \(error.localizedDescription)"
            rebuildTools()
            Log.ai.error("stdio MCP server \(server.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public) stderr: \(stderr, privacy: .public)")
        }
    }

    private func rebuildTools() {
        var defs: [AgentToolDef] = []
        var routes: [String: (serverID: UUID, toolName: String)] = [:]
        for server in servers where server.isEnabled {
            // HTTP 与 stdio 两种连接任一存活即可（stdio 的连接表是
            // stdioConnections——只查 connections 会把 stdio 工具全部漏掉）。
            guard connections[server.id] != nil || stdioConnections[server.id] != nil,
                  let tools = cachedTools[server.id] else { continue }
            for tool in tools {
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
        Log.ai.info("MCP rebuildTools: defs=\(defs.count, privacy: .public) http=\(self.connections.count, privacy: .public) stdio=\(self.stdioConnections.count, privacy: .public) enabled=\(self.servers.filter(\.isEnabled).count, privacy: .public)")
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
        guard let route = toolRoutes[defName] else {
            Log.ai.error("MCP callTool: route missing for \(defName, privacy: .public) — routes=\(self.toolRoutes.count, privacy: .public) http=\(self.connections.count, privacy: .public) stdio=\(self.stdioConnections.count, privacy: .public) defs=\(self.toolDefs.count, privacy: .public)")
            // 失败约定与 BrowserToolProvider.fail 一致（Error: 前缀）：
            // 模型与机械核验都靠它识别"这次调用没有成功"。
            return "Error: MCP tool unavailable — server disconnected"
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        // stdio 传输分派
        if let stdio = stdioConnections[route.serverID] {
            do {
                let text = try await stdio.callTool(named: route.toolName, arguments: arguments)
                Log.ai.info("stdio MCP tool ok: \(route.toolName, privacy: .public)")
                return text
            } catch {
                Log.ai.error("stdio MCP tool failed: \(route.toolName, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                return "Error: MCP tool error: \(error.localizedDescription)"
            }
        }
        guard var connection = connections[route.serverID] else {
            Log.ai.error("MCP callTool: no connection for \(defName, privacy: .public) — routes=\(self.toolRoutes.count, privacy: .public) stdio=\(self.stdioConnections.count, privacy: .public) http=\(self.connections.count, privacy: .public)")
            return "Error: MCP tool unavailable — server disconnected"
        }
        do {
            let text = try await connection.callTool(named: route.toolName, arguments: arguments)
            connections[route.serverID] = connection
            return text
        } catch {
            connections[route.serverID] = connection
            return "Error: MCP tool error: \(error.localizedDescription)"
        }
    }
}
