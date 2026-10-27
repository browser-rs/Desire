import Foundation

/// 集中搜索（Search Everywhere，0.7.14）的**纯查询逻辑**——跨打开标签/历史/
/// 书签/阅读列表四源同搜。Foundation-only：进 tests/run.sh。
/// UI（SearchEverywherePanel）与桥端点（/search/everything）共用此查询。
nonisolated enum SearchEverywhere {

    enum Source: String, CaseIterable, Sendable {
        case tab, history, bookmark, readingList
        /// Agent 会话（0.7.14 第五源：标题/消息文本命中，回车直达会话）。
        case agentConversation
        /// 最近本地文件（v0.8.15 第六源：文件名 + 内容快照命中，回车进查看器）。
        case localFile
    }

    struct Hit: Identifiable, Equatable, Sendable {
        let source: Source
        let id: String
        let title: String
        let url: String
        /// 命中来源字段（title/url/content——高亮定位与调试用）。
        let matchedIn: String
        /// content 命中时命中处前后的一小段原文（列表副标题显示）。
        var snippet: String? = nil
        /// Agent 会话命中消息（打开会话后跳转高亮这一轮）。
        var targetMessageID: UUID? = nil
        /// 触发命中的查询（打开后查找框预填）。
        var matchedQuery: String? = nil

        static func == (lhs: Hit, rhs: Hit) -> Bool {
            lhs.source == rhs.source && lhs.id == rhs.id
        }
    }

    struct Result: Equatable, Sendable {
        var tabs: [Hit] = []
        var history: [Hit] = []
        var bookmarks: [Hit] = []
        var readingList: [Hit] = []
        var agentConversations: [Hit] = []
        var localFiles: [Hit] = []

        var isEmpty: Bool {
            tabs.isEmpty && history.isEmpty && bookmarks.isEmpty
                && readingList.isEmpty && agentConversations.isEmpty
                && localFiles.isEmpty
        }
        var totalCount: Int {
            tabs.count + history.count + bookmarks.count + readingList.count
                + agentConversations.count + localFiles.count
        }
    }

    // MARK: - Inputs（调用方把各源裁成轻量行——纯函数不依赖 store 类型）

    struct Item: Sendable {
        let source: Source
        let id: String
        let title: String
        let url: String
        /// 额外正文（Agent 会话消息文本；调用方已算好命中片段）。
        var snippet: String? = nil
        /// Agent 会话命中消息（跳转高亮目标）；其他源为 nil。
        var targetMessageID: UUID? = nil
        /// 触发命中的查询（打开后查找框预填）。
        var matchedQuery: String? = nil
    }

    // MARK: - Query

    /// 空查询 = nil（面板显示默认态，不返回全量）。每源限 20 条，
    /// 排序：title 命中 > url 命中，同组内按原有顺序（调用方传入即近期序）。
    static func search(_ query: String, items: [Item], limitPerSource: Int = 20) -> Result {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Result() }

        var result = Result()
        var counts: [Source: Int] = [:]

        for item in items {
            guard let source = item.source as Source? else { continue }
            guard (counts[source] ?? 0) < limitPerSource else { continue }
            let titleHit = item.title.lowercased().contains(q)
            let urlHit = item.url.lowercased().contains(q)
            let contentHit = item.snippet?.lowercased().contains(q) == true
            guard titleHit || urlHit || contentHit else { continue }
            let hit = Hit(source: item.source, id: item.id,
                          title: item.title, url: item.url,
                          matchedIn: titleHit ? "title" : (contentHit ? "content" : "url"),
                          snippet: contentHit ? item.snippet : nil,
                          targetMessageID: item.targetMessageID,
                          matchedQuery: item.matchedQuery)
            switch source {
            case .tab: result.tabs.append(hit)
            case .history: result.history.append(hit)
            case .bookmark: result.bookmarks.append(hit)
            case .readingList: result.readingList.append(hit)
            case .agentConversation: result.agentConversations.append(hit)
            case .localFile: result.localFiles.append(hit)
            }
            counts[source, default: 0] += 1
        }
        return result
    }

    /// 从标签标题/URL 生成查询用 Item。
    static func item(source: Source, id: String, title: String, url: String) -> Item {
        Item(source: source, id: id, title: title, url: url)
    }
}
