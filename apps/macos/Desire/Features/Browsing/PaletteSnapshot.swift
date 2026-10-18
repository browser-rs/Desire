import Foundation
import WebKit

/// 命令面板五源快照的**单点构建**（UI 首开与桥 `/palette` 共用——同一处行
/// 构造，避免两个入口的检索结果漂移）。各源截断上限就低（历史 300 /
/// 会话 120）：面板是"最近优先"的检索，不必扫全库；输入顺序即时间序
/// （PaletteSearch 同分保持输入序，稳定排序由它显式兜底）。
@MainActor
enum PaletteSnapshot {

    /// 命令以外的四源行（命令行的目录与最近使用排序在 `CommandPalette`）。
    static func rows(tabManager: TabManager?,
                     bookmarkStore: BookmarkStore,
                     historyStore: HistoryStore,
                     conversationStore: ConversationStore) -> [PaletteSearch.Row] {
        var rows: [PaletteSearch.Row] = []

        // 打开中的标签（窗口顺序 = 用户心智序）。
        if let tabs = tabManager?.tabs {
            for tab in tabs {
                let url = tab.browser.webView.url?.absoluteString ?? tab.urlString
                rows.append(.init(source: .tab, id: tab.id.uuidString,
                                  title: tab.displayTitle.isEmpty ? url : tab.displayTitle,
                                  subtitle: url, url: url))
            }
        }

        // 书签（叶子）。
        for entry in bookmarkStore.leafEntries {
            rows.append(.init(source: .bookmark, id: entry.url,
                              title: entry.title, subtitle: entry.url, url: entry.url))
        }

        // 历史（最近 300 条，已是新→旧）。
        for entry in historyStore.recentEntries(count: 300) {
            rows.append(.init(source: .history, id: entry.url,
                              title: entry.title, subtitle: entry.url, url: entry.url))
        }

        // Agent 会话（最近 120；副标题 = 首条用户消息摘要）。
        for conversation in conversationStore.conversations
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .prefix(120) {
            let first = conversation.messages.first(where: { $0.role == .user })?.content ?? ""
            let snippet = first
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(.init(source: .conversation, id: conversation.id.uuidString,
                              title: conversation.title.isEmpty
                                  ? String(localized: "Untitled") : conversation.title,
                              subtitle: String(snippet.prefix(80))))
        }

        return rows
    }
}
