import Foundation

/// 上下文压缩：把发给模型的消息裁进预算。
///
/// **口径**：预算按**字符**（与输入框旁的"上下文占用%"同源，非 token —— token 需按
/// 模型分词，端上没有可靠的估算器；已落盘的逐条 `promptTokens` 可以用来校准，见优化清单）。
enum ContextCompaction {
    /// Drops the OLDEST user-started conversation blocks while the estimated
    /// context size exceeds the budget. A block runs from a user message up
    /// to the next user message, so assistant tool_calls and their tool
    /// results always stay together — the provider's tool-call→tool-result
    /// pairing is never broken. The final block is never dropped.
    static func compact(_ messages: [AgentMessage], budget: Int = 160_000) -> [AgentMessage] {
        func size(_ m: AgentMessage) -> Int {
            (m.content?.count ?? 0)
                + (m.toolCalls?.reduce(0) { $0 + $1.function.arguments.count + $1.function.name.count } ?? 0)
        }
        let sizes = messages.map(size)
        var total = sizes.reduce(0, +)
        guard total > budget else { return messages }

        let starts = messages.indices.filter { messages[$0].role == .user }
        guard starts.count > 1 else { return messages }

        var keepStart = 0
        for (i, s) in starts.enumerated() {
            if total <= budget { break }
            if i == starts.count - 1 { break }   // never drop the final block
            let end = i + 1 < starts.count ? starts[i + 1] : messages.count
            total -= (s..<end).reduce(0) { $0 + sizes[$1] }
            keepStart = end
        }
        guard keepStart > 0 else { return messages }
        return Array(messages[keepStart...])
    }
}
