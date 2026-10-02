import Foundation

/// A remote MCP (Model Context Protocol) server speaking the Streamable
/// HTTP transport. HTTP is used instead of stdio because Desire is a
/// sandboxed app — spawned child processes would inherit the sandbox and
/// could not run arbitrary MCP servers; local servers can be exposed over
/// HTTP with any stdio-to-HTTP bridge outside the app.
struct MCPServer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Streamable HTTP endpoint, e.g. http://127.0.0.1:3000/mcp
    var url: String
    var isEnabled: Bool = true
    /// Optional Bearer token sent as `Authorization: Bearer <token>`.
    /// Optional so configs saved before this field decode as nil.
    var authToken: String? = nil
    /// 传输层（2026-10-02 完整 MCP）：nil/"http" = Streamable HTTP（url 字段）；
    /// "stdio" = 本地子进程（command argv + 可选 env）。Optional = 旧配置解码安全。
    var transport: String? = nil
    /// stdio argv：argv[0] = 可执行文件路径，其余为参数。
    var command: [String]? = nil
    /// stdio 子进程的额外环境变量。
    var env: [String: String]? = nil

    var isStdio: Bool { transport == "stdio" }
}
