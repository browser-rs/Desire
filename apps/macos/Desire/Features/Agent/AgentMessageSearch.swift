import Foundation

/// 会话内查找的**纯逻辑**（v0.7.21；Foundation-only 进 harness）。
/// 面板的查找条与桥 `/agent/find` 共用——命中口径只有一处。
nonisolated enum AgentMessageSearch {

    /// 命中消息 id（按会话顺序；大小写不敏感子串）。
    /// 只扫 `content`：纯工具调用消息在面板上是卡片、推理是折叠块，
    /// 对"找那句话"没有帮助（也避免命中噪音）。
    static func matches(messages: [AgentMessage], query: String) -> [UUID] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return messages.compactMap { message in
            guard let content = message.content,
                  !content.isEmpty,
                  content.lowercased().contains(q) else { return nil }
            return message.id
        }
    }
}
