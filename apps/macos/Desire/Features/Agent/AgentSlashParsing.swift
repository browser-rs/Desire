import Foundation

/// Agent 面板 slash 命令（2026-10-10）：输入框里 `/命令 [参数]` 触发本地
/// 动作，不发给模型。解析与执行分离——本文件是**纯解析半边**（Foundation-only，
/// 进 tests/run.sh）；执行在 `AgentSessionStore.sendMessage` 顶部拦截。
/// 首词不是已知命令 → 原样发给模型（路径、以 / 开头的问题不受影响）。
nonisolated enum AgentSlashParsing {
    struct Parsed: Equatable {
        let command: String        // 小写、不带斜杠
        let argument: String       // 其余文本（已 trim；可为空）
    }

    /// 已知命令清单（/help 的输出与拦截判据同源）。
    static let known: [String] = [
        "help", "new", "compact", "stats", "doctor", "mode", "resume",
        "skills", "memory", "model", "persona", "plan", "cancel", "windows",
        // 2026-10-10 二批：访问等级 / 会话指令 / 定时任务 / 工具清单 / MCP /
        // 重命名 / 重试 / 导出。
        "access", "directive", "tasks", "tools", "mcp", "title", "retry", "export",
    ]

    /// 命令一句话说明（/help 输出与输入框候选菜单同源，防漂移）。
    nonisolated static let descriptions: [String: String] = [
        "help": String(localized: "show this list"),
        "new": String(localized: "start a fresh conversation"),
        "compact": String(localized: "shrink the context budget now (older turns stay recallable)"),
        "stats": String(localized: "token usage and cost for this conversation"),
        "doctor": String(localized: "run the agent self-check"),
        "mode": String(localized: "switch agent mode: /mode standard|research|writing"),
        "resume": String(localized: "continue the interrupted turn"),
        "skills": String(localized: "list installed skills"),
        "memory": String(localized: "memory summary (profile, facts, summaries)"),
        "model": String(localized: "list model services, or switch: /model <名称>"),
        "persona": String(localized: "list personas, or bind: /persona <名字>（off = unbind）"),
        "plan": String(localized: "show the current plan checklist"),
        "cancel": String(localized: "cancel the running turn"),
        "windows": String(localized: "list windows and their agent state"),
        "access": String(localized: "show or set access level: /access confirm|auto|full"),
        "directive": String(localized: "show, set, or clear the session instruction: /directive <text>（off = clear）"),
        "tasks": String(localized: "list scheduled tasks"),
        "tools": String(localized: "count tools by risk tier, or filter: /tools <关键词>"),
        "mcp": String(localized: "list MCP servers and connection status"),
        "title": String(localized: "rename this conversation: /title <新标题>"),
        "retry": String(localized: "re-run the last answer"),
        "export": String(localized: "save this conversation as a Markdown file"),
    ]

    static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let command = first.lowercased()
        guard known.contains(command) else { return nil }
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return Parsed(command: command, argument: argument)
    }

    /// /help 的输出（命令清单与一句话说明，与候选菜单同源防漂移）。
    nonisolated static func helpText() -> String {
        known.map { "/\($0) — \(descriptions[$0] ?? "")" }.joined(separator: "\n")
    }

    /// 输入候选：按 "/" 后的前缀过滤（命令 + 本地化说明）。
    nonisolated static func suggestions(prefix: String) -> [(command: String, description: String)] {
        let p = prefix.lowercased()
        return known.compactMap { cmd in
            guard cmd.hasPrefix(p) else { return nil }
            return (cmd, descriptions[cmd] ?? "")
        }
    }
}
