import Foundation

/// 会话导出（Markdown）的**纯逻辑半边**：面板右键"Export as Markdown"与
/// slash `/export` 共用同一份渲染，保证两条路导出的文件一字不差。
/// Foundation-only：进 tests/run.sh。
nonisolated enum AgentConversationExport {
    static func markdown(_ messages: [AgentMessage]) -> String {
        messages.map { message -> String in
            switch message.role {
            case .user:
                return "## 🧑 User\n\n\(message.content ?? "")"
            case .assistant:
                let calls = (message.toolCalls ?? []).map { "`\($0.function.name)`" }.joined(separator: ", ")
                var body = "## 🤖 Agent\n\n"
                if !calls.isEmpty { body += "_tools: \(calls)_\n\n" }
                if let content = message.content, !content.isEmpty { body += content }
                return body
            case .tool:
                return "> tool result: \((message.content ?? "").prefix(600))"
            case .system:
                return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n---\n\n")
    }
}
