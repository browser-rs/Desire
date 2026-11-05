import Combine
import Foundation

/// 订阅库（v0.8.45 批 1）：订阅列表 + 文章台账，DiskStore 快照落盘
/// （`feeds.library`，500ms 防抖）。抓取合入走 `FeedCore.merge` 的纯逻辑；
/// 本 Store 只管持有、持久化与查询视图。抓取器/定时在批 2 接入。
@MainActor
final class FeedStore: ObservableObject {
    static let shared = FeedStore()

    static let storeKey = "feeds.library"

    @Published private(set) var feeds: [Feed] = []
    @Published private(set) var items: [FeedItem] = []

    init() {
        if let library = DiskStore.load(FeedLibrary.self, key: Self.storeKey) {
            feeds = library.feeds
            items = library.items
        }
    }

    private func persist() {
        DiskStore.save(FeedLibrary(feeds: feeds, items: items), key: Self.storeKey)
    }

    // MARK: - 订阅

    /// 订阅（按 url 去重；已存在返回既有条目）。
    @discardableResult
    func addFeed(url: String, title: String, siteURL: String?,
                 feedDescription: String?) -> Feed {
        if let existing = feeds.first(where: { $0.url == url }) {
            // 标题/站点信息随抓取刷新（首次订阅时解析出的元数据）
            if existing.title.isEmpty, !title.isEmpty {
                var updated = existing
                updated.title = title
                updated.siteURL = updated.siteURL ?? siteURL
                updated.syncUpdatedAt = Date()
                replaceFeed(updated)
            }
            return existing
        }
        let feed = Feed(id: UUID(), url: url,
                        title: title.isEmpty ? url : title,
                        siteURL: siteURL, feedDescription: feedDescription,
                        addedAt: Date(), lastFetchedAt: nil, lastError: nil,
                        etag: nil, lastModified: nil,
                        syncUpdatedAt: Date())
        feeds.insert(feed, at: 0)
        persist()
        return feed
    }

    func removeFeed(url: String) {
        feeds.removeAll { $0.url == url }
        items.removeAll { $0.feedURL == url }
        persist()
    }

    func feed(url: String) -> Feed? {
        feeds.first { $0.url == url }
    }

    /// 按源通知分级（丰富批）：true = urgent 直推；nil/false = routine 门控。
    func setUrgentNotifications(_ url: String, enabled: Bool?) {
        guard let index = feeds.firstIndex(where: { $0.url == url }) else { return }
        feeds[index].urgentNotifications = enabled
        persist()
    }

    private func replaceFeed(_ feed: Feed) {
        guard let index = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[index] = feed
        persist()
    }

    // MARK: - 抓取合入（批 2 抓取器调用）

    /// 把一次抓取结果合入台账。`newCount` 供通知/简报使用。
    @discardableResult
    func applyFetch(feedURL: String, meta: FeedCore.FeedMeta?,
                    drafts: [FeedCore.ItemDraft], etag: String?,
                    lastModified: String?, error: String?) -> Int {
        guard let index = feeds.firstIndex(where: { $0.url == feedURL }) else {
            return 0
        }
        feeds[index].lastFetchedAt = Date()
        feeds[index].etag = etag ?? feeds[index].etag
        feeds[index].lastModified = lastModified ?? feeds[index].lastModified
        feeds[index].lastError = error
        if let meta, feeds[index].title.isEmpty || meta.title.isEmpty == false {
            // 首次拿到正式标题就补上（订阅时可能只有 URL）
            if feeds[index].title == feedURL, !meta.title.isEmpty {
                feeds[index].title = meta.title
                feeds[index].syncUpdatedAt = Date()
            }
            feeds[index].siteURL = feeds[index].siteURL ?? meta.siteURL
            feeds[index].feedDescription = feeds[index].feedDescription ?? meta.feedDescription
        }
        let (merged, newCount) = FeedCore.merge(
            existing: items.filter { $0.feedURL == feedURL },
            drafts: drafts, feedURL: feedURL, fetchedAt: Date())
        items.removeAll { $0.feedURL == feedURL }
        items.append(contentsOf: merged)
        persist()
        return newCount
    }

    // MARK: - 文章状态

    func markRead(_ id: String, read: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isRead = read
        persist()
    }

    func toggleStar(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isStarred.toggle()
        persist()
    }

    func markAllRead(feedURL: String? = nil) {
        let targets: [Int] = feedURL == nil
            ? Array(items.indices)
            : items.indices.filter { items[$0].feedURL == feedURL }
        for index in targets where items[index].isRead == false {
            items[index].isRead = true
        }
        persist()
    }

    // MARK: - 查询视图

    func articles(for feedURL: String? = nil, unreadOnly: Bool = false) -> [FeedItem] {
        items
            .filter { feedURL == nil || $0.feedURL == feedURL }
            .filter { !unreadOnly || !$0.isRead }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    func unreadCount(for feedURL: String? = nil) -> Int {
        items.filter { feedURL == nil || $0.feedURL == feedURL }
            .filter { !$0.isRead }.count
    }

    // MARK: - 同步回写（v0.8.45 第十六域；调用方用 SyncStore.applyRemotely 包裹）

    /// 应用远端快照变更：增/删订阅 + 已读/星标对齐（只动本地存在的文章 id）。
    /// 单次 persist；objectWillChange 由 SyncStore 的 applyingRemote 守卫吞掉。
    func applySyncChanges(_ changes: FeedSyncCore.RemoteChanges) {
        for def in changes.addFeeds {
            if feed(url: def.url) == nil {
                let item = Feed(id: UUID(), url: def.url, title: def.title,
                                siteURL: def.siteURL, feedDescription: nil,
                                addedAt: Date(), lastFetchedAt: nil,
                                lastError: nil, etag: nil, lastModified: nil,
                                collection: def.collection,
                                syncUpdatedAt: Date())
                feeds.append(item)
            }
        }
        for url in changes.removeFeedURLs {
            feeds.removeAll { $0.url == url }
            items.removeAll { $0.feedURL == url }
        }
        let readBy = Dictionary(uniqueKeysWithValues: changes.readUpdates.map { ($0.id, $0.read) })
        let starBy = Dictionary(uniqueKeysWithValues: changes.starUpdates.map { ($0.id, $0.starred) })
        for index in items.indices {
            if let read = readBy[items[index].id] { items[index].isRead = read }
            if let starred = starBy[items[index].id] { items[index].isStarred = starred }
        }
        persist()
    }
}
