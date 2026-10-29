import Combine
import Foundation

/// 各数据源 → 语义条目的**取数口**（v0.8.22）。读 store 的动作都在这层
/// （主线程、快照式），嵌入与落盘在 `SemanticIndexStore` 的后台任务里。
///
/// 隐私口径：会话消息默认**不**进索引（用户可在设置里显式打开）；
/// 历史正文跟随"历史正文索引"自己的 opt-in 开关；所有内容只在本机，
/// 不进同步、不进备份。
@MainActor
enum SemanticIndexSources {
    static func items(for source: SemanticSource) -> [SemanticItem] {
        switch source {
        case .history:
            guard HistoryContentStore.shared.isEnabled else { return [] }
            return SemanticSnapshots.history(HistoryContentStore.shared.records)
        case .bookmark:
            guard let app = AppState.live else { return [] }
            return SemanticSnapshots.bookmarks(app.bookmarkStore.bookmarks)
        case .excerpt:
            return SemanticSnapshots.excerpts(ExcerptStore.shared.excerpts)
        case .highlight:
            return SemanticSnapshots.highlights(ReaderHighlightStore.shared.highlights)
        case .conversation:
            return conversationItems()
        }
    }

    /// 会话：最近 200 个会话 × 每个会话最后 40 条有正文的 user/assistant
    /// 消息。过短的消息（"好的"）不入索引——它们没有检索价值，还占向量。
    private static func conversationItems() -> [SemanticItem] {
        guard let store = AppState.live?.conversationStore else { return [] }
        let conversations = store.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(200)
        var items: [SemanticItem] = []
        for conversation in conversations {
            let messages = conversation.messages
                .filter { ($0.role == .user || $0.role == .assistant) }
                .suffix(40)
            for message in messages {
                guard let raw = message.content else { continue }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 8 else { continue }
                let lead = SemanticText.clip(SemanticText.collapseWhitespace(text), max: 100)
                items.append(SemanticItem(
                    source: .conversation,
                    externalID: "\(conversation.id.uuidString):\(message.id.uuidString)",
                    title: lead,
                    subtitle: conversation.title,
                    body: text,
                    updatedAt: conversation.updatedAt))
            }
        }
        return items
    }
}
