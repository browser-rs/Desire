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
}
