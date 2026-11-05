import Foundation

/// 订阅源与文章（v0.8.45 第十六同步域的客户端模型）。
/// Foundation-only，进 tests/run.sh。文章台账只存元数据（标题/链接/摘要），
/// 正文在阅读模式打开时由 Reader 管线现取。
nonisolated struct Feed: Codable, Identifiable, Equatable {
    var id: UUID
    /// feed 文档 URL（抓取地址）
    var url: String
    var title: String
    /// 站点主页（Atom htmlLink / RSS 常缺）
    var siteURL: String?
    var feedDescription: String?
    var addedAt: Date
    var lastFetchedAt: Date?
    var lastError: String?
    /// HTTP 缓存协商（抓取器用；nil = 未协商过）
    var etag: String?
    var lastModified: String?
    /// 分组名（可选）
    var collection: String? = nil
    /// 同步 LWW 戳
    var syncUpdatedAt: Date? = nil
    /// 新文章通知直推（urgent）；nil/false = routine（免打扰/预算门控照常）。
    var urgentNotifications: Bool? = nil

    var urlOrEmpty: String { url }

    /// 有效分组名（空白视为无分组；书架同语义）。
    var collectionName: String? {
        guard let name = collection?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.isEmpty == false else { return nil }
        return name
    }
}

nonisolated struct FeedItem: Codable, Identifiable, Equatable {
    /// 稳定 id：guid（缺省 link，再缺省 title 派生）——去重与同步的键。
    var id: String
    var feedURL: String
    var title: String
    var link: String?
    /// 解析失败时用抓取时间（排序与展示）
    var publishedAt: Date
    var summary: String?
    var author: String?
    var isRead: Bool
    var isStarred: Bool
    var firstSeenAt: Date

    var displayDate: Date { publishedAt }
}

/// 落盘快照（DiskStore `feeds.library`；Store 文件不放 Codable struct）。
nonisolated struct FeedLibrary: Codable, Equatable {
    var feeds: [Feed] = []
    var items: [FeedItem] = []
}
