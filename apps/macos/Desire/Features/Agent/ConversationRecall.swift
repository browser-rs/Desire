import Foundation

/// 按需回忆：当前会话的完整历史**永在
/// 内存与盘上**，只是被压缩裁出了请求上下文。这个纯函数把「查询 → 命中轮次
/// 片段」的挑选逻辑独立出来供 recallConversation 工具调用，进 tests/run.sh。
nonisolated enum ConversationRecall {
    struct Hit {
        let index: Int          // messages 数组下标（调试/引用用）
        let role: String
        let excerpt: String
    }

    /// 在消息数组里按关键词挑出命中轮次（跳过 system/空内容），每条截
    /// excerptChars，总输出不超过 maxHits 条。命中判定大小写不敏感。
    static func pick(_ messages: [(index: Int, role: String, content: String)],
                     query: String,
                     maxHits: Int = 6,
                     excerptChars: Int = 700) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [Hit] = []
        for (index, role, content) in messages where role != "system" && !content.isEmpty {
            if content.localizedCaseInsensitiveContains(q) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let excerpt = trimmed.count > excerptChars
                    ? String(trimmed.prefix(excerptChars)) + "…"
                    : trimmed
                hits.append(Hit(index: index, role: role, excerpt: excerpt))
                if hits.count >= maxHits { break }
            }
        }
        return hits
    }

    /// 工具结果的组装（含"这是历史召回、非当前上下文"的定位说明）。
    static func render(hits: [Hit], query: String, totalMessages: Int) -> String {
        guard !hits.isEmpty else {
            return "No matches for \"\(query)\" in this conversation's full history (\(totalMessages) messages)."
        }
        var out = "Recalled \(hits.count) hit(s) for \"\(query)\" from the FULL conversation history " +
            "(\(totalMessages) messages — older turns may be outside your current context window):\n"
        for hit in hits {
            out += "\n[\(hit.index)] \(hit.role): \(hit.excerpt)"
        }
        return out
    }
}
