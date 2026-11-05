import Foundation

/// feeds 同步域（v0.8.45 第十六域）的载荷与合并纯逻辑。
/// Foundation-only，进 tests/run.sh。语义 = **整体快照 LWW**（同 settings/
/// agentPrefs 家族）：payload = 订阅定义 + 已读/星标 id 集合；文章正文不入库
/// （各设备自行抓取），退订/换机靠"远端列表里没有 = 删"。
nonisolated struct FeedSyncPayload: Codable, Equatable, Sendable {
    struct FeedDef: Codable, Equatable, Sendable {
        var url: String
        var title: String
        var siteURL: String?
        var collection: String?
    }

    var feeds: [FeedDef]
    var readIDs: [String]
    var starredIDs: [String]
}

nonisolated enum FeedSyncCore {

    /// 本地台账 → 同步快照。
    static func buildPayload(feeds: [Feed], items: [FeedItem]) -> FeedSyncPayload {
        FeedSyncPayload(
            feeds: feeds.map {
                FeedSyncPayload.FeedDef(url: $0.url, title: $0.title,
                                        siteURL: $0.siteURL,
                                        collection: $0.collection)
            },
            readIDs: items.filter(\.isRead).map(\.id),
            starredIDs: items.filter(\.isStarred).map(\.id))
    }

    /// 远端快照 → 本地应做的变更（Store 据此 applyRemotely 包裹回写）：
    /// - addFeeds：本地没有的订阅定义；
    /// - removeFeedURLs：远端已不存在的订阅（含其文章一并清）；
    /// - readUpdates / starUpdates：只对本地还存在的文章 id 生效。
    struct RemoteChanges: Equatable, Sendable {
        var addFeeds: [FeedSyncPayload.FeedDef]
        var removeFeedURLs: [String]
        var readUpdates: [(id: String, read: Bool)]
        var starUpdates: [(id: String, starred: Bool)]

        static func == (lhs: RemoteChanges, rhs: RemoteChanges) -> Bool {
            lhs.addFeeds == rhs.addFeeds && lhs.removeFeedURLs == rhs.removeFeedURLs
                && lhs.readUpdates.map(\.id) == rhs.readUpdates.map(\.id)
                && lhs.readUpdates.map(\.read) == rhs.readUpdates.map(\.read)
                && lhs.starUpdates.map(\.id) == rhs.starUpdates.map(\.id)
                && lhs.starUpdates.map(\.starred) == rhs.starUpdates.map(\.starred)
        }
    }

    static func remoteChanges(payload: FeedSyncPayload,
                              localFeeds: [Feed],
                              localItems: [FeedItem]) -> RemoteChanges {
        let remoteURLs = Set(payload.feeds.map(\.url))
        let localURLs = Set(localFeeds.map(\.url))
        let addFeeds = payload.feeds.filter { !localURLs.contains($0.url) }
        let removeFeedURLs = localURLs.subtracting(remoteURLs).sorted()

        let localByID = Dictionary(localItems.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let readSet = Set(payload.readIDs)
        let starSet = Set(payload.starredIDs)
        var readUpdates: [(id: String, read: Bool)] = []
        var starUpdates: [(id: String, starred: Bool)] = []
        for (id, item) in localByID {
            let remoteRead = readSet.contains(id)
            if item.isRead != remoteRead {
                readUpdates.append((id, remoteRead))
            }
            let remoteStarred = starSet.contains(id)
            if item.isStarred != remoteStarred {
                starUpdates.append((id, remoteStarred))
            }
        }
        return RemoteChanges(addFeeds: addFeeds,
                             removeFeedURLs: removeFeedURLs,
                             readUpdates: readUpdates.sorted { $0.id < $1.id },
                             starUpdates: starUpdates.sorted { $0.id < $1.id })
    }
}
