import Foundation

/// 摘录 ↔ 白板/会话的反向引用（v0.8.25）：给定摘录正文，扫描白板块与会话消息
/// 里是否出现过它。纯逻辑（进 harness），数字派生于内容本身、不额外埋点。
nonisolated struct ExcerptBacklink: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case whiteboard
        case conversation
    }

    var kind: Kind
    var conversationID: String
    var title: String
    var snippet: String

    var id: String { "\(kind.rawValue):\(conversationID):\(snippet)" }
}

nonisolated enum ExcerptBacklinkCore {
    /// 小写 + 空白折叠（比较口径；标点保留）。
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 探测串：归一化后的前 `maxLength` 个字符（太短容易误报）。
    static func probe(_ content: String, maxLength: Int = 80) -> String {
        let normalized = normalize(content)
        return String(normalized.prefix(maxLength))
    }

    struct Board: Equatable, Sendable {
        var conversationID: String
        var title: String
        /// 已拼好的白板块文本（调用方归一化前）。
        var text: String
    }

    struct ConversationRef: Equatable, Sendable {
        var conversationID: String
        var title: String
        var text: String
    }

    /// 每个摘录最多返回的引用数（两源合计）。
    static let maxHitsPerExcerpt = 8
    /// 探测串最短长度：低于 12 个字符不参与反查（避免单句误报）。
    static let minProbeLength = 12

    static func scan(excerpts: [Excerpt], boards: [Board],
                     conversations: [ConversationRef],
                     maxHits: Int = ExcerptBacklinkCore.maxHitsPerExcerpt) -> [UUID: [ExcerptBacklink]] {
        guard !excerpts.isEmpty, !(boards.isEmpty && conversations.isEmpty) else { return [:] }
        // 归一化只做一次（每个摘录 × 每份文本各查一次，不必重复折叠）。
        let boardTexts = boards.map { ($0, normalize($0.text)) }
        let conversationTexts = conversations.map { ($0, normalize($0.text)) }

        var out: [UUID: [ExcerptBacklink]] = [:]
        for excerpt in excerpts {
            let probe = probe(excerpt.content)
            guard probe.count >= minProbeLength else { continue }
            var hits: [ExcerptBacklink] = []
            for (board, text) in boardTexts where text.contains(probe) {
                hits.append(ExcerptBacklink(kind: .whiteboard,
                                            conversationID: board.conversationID,
                                            title: board.title,
                                            snippet: String(localized: "Whiteboard block")))
                break
            }
            for (conversation, text) in conversationTexts where text.contains(probe) {
                hits.append(ExcerptBacklink(kind: .conversation,
                                            conversationID: conversation.conversationID,
                                            title: conversation.title,
                                            snippet: String(localized: "Conversation message")))
            }
            if !hits.isEmpty { out[excerpt.id] = Array(hits.prefix(maxHits)) }
        }
        return out
    }
}
