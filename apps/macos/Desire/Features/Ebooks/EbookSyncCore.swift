import Foundation

/// 电子书同步（v0.8.37）：book/bookmark 两种 payload + 合并规则。
/// 纯逻辑，进 harness；SyncStore 只负责加密/推送/游标。
nonisolated struct EbookSyncBookPayload: Codable, Equatable, Sendable {
    var hash: String
    var title: String
    var author: String
    var format: String
    var collection: String?
    var favorite: Bool
    var progress: Double
    var lastChapterIndex: Int
    var chapterProgress: Double
    var chapterCount: Int
    var lastOpenedAt: Date?
    /// 元数据（标题/作者/分组/收藏）的 LWW 戳；进度不用它裁决。
    var updatedAt: Date
}

nonisolated struct EbookSyncBookmarkPayload: Codable, Equatable, Sendable {
    var bookHash: String
    var bookmark: EbookBookmark
    /// 保留字段；书签内容不可变，删除走 tombstone。
    var updatedAt: Date
}

nonisolated enum EbookSyncCore {

    static func bookID(hash: String) -> String {
        "book:\(hash.lowercased())"
    }

    static func bookmarkID(bookHash: String, bookmarkID: UUID) -> String {
        "bookmark:\(bookHash.lowercased()):\(bookmarkID.uuidString.lowercased())"
    }

    /// 本地书 + 远端书条目 → 合并后的书。
    /// - 元数据：远端 `updatedAt` 更新则采用远端标题/作者/分组/收藏；
    /// - 进度：**取最远**（相等时看 lastOpenedAt），绝不倒退；
    /// - lastOpenedAt 总是取较大值。
    static func mergeBook(local: Ebook, remote: EbookSyncBookPayload) -> Ebook {
        var result = local
        let localStamp = local.syncUpdatedAt ?? local.addedAt
        if remote.updatedAt >= localStamp {
            result.title = remote.title.isEmpty ? local.title : remote.title
            result.author = remote.author
            result.collection = remote.collection
            result.isFavorite = remote.favorite
            if let format = EbookFormat(rawValue: remote.format) {
                result.format = format
            }
            result.syncUpdatedAt = remote.updatedAt
        }
        let remoteProgress = min(max(remote.progress, 0), 1)
        let remoteOpened = remote.lastOpenedAt ?? .distantPast
        let localOpened = local.lastOpenedAt ?? .distantPast
        if remoteProgress > result.progress
            || (abs(remoteProgress - result.progress) < 0.0001 && remoteOpened > localOpened) {
            result.progress = remoteProgress
            result.lastChapterIndex = max(0, remote.lastChapterIndex)
            result.chapterProgress = min(max(remote.chapterProgress, 0), 1)
        }
        if remoteOpened > (result.lastOpenedAt ?? .distantPast) {
            result.lastOpenedAt = remoteOpened
        }
        if remote.chapterCount > 0 {
            result.chapterCount = max(result.chapterCount, remote.chapterCount)
        }
        return result
    }

    /// 本地书签 + 远端书签并集；`deletedIDs` 是已解密 tombstone 对应的 UUID。
    static func mergeBookmarks(local: [EbookBookmark],
                               remote: [EbookSyncBookmarkPayload],
                               deletedIDs: Set<UUID>) -> [EbookBookmark] {
        var byID: [UUID: EbookBookmark] = [:]
        for bookmark in local where !deletedIDs.contains(bookmark.id) {
            byID[bookmark.id] = bookmark
        }
        for payload in remote where !deletedIDs.contains(payload.bookmark.id) {
            byID[payload.bookmark.id] = payload.bookmark
        }
        return byID.values.sorted {
            if $0.chapterIndex != $1.chapterIndex { return $0.chapterIndex < $1.chapterIndex }
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return $0.createdAt < $1.createdAt
        }
    }

    /// 由书签列表构造远端 payload。
    static func bookmarkPayloads(bookHash: String,
                                 bookmarks: [EbookBookmark]) -> [EbookSyncBookmarkPayload] {
        bookmarks.map {
            EbookSyncBookmarkPayload(bookHash: bookHash, bookmark: $0,
                                 updatedAt: $0.createdAt)
        }
    }

    static func bookPayload(_ book: Ebook) -> EbookSyncBookPayload {
        EbookSyncBookPayload(
            hash: book.hash,
            title: book.title,
            author: book.author,
            format: book.format.rawValue,
            collection: book.collection,
            favorite: book.favorite,
            progress: book.progress,
            lastChapterIndex: book.lastChapterIndex,
            chapterProgress: book.chapterProgress,
            chapterCount: book.chapterCount,
            lastOpenedAt: book.lastOpenedAt,
            updatedAt: book.syncUpdatedAt ?? book.addedAt)
    }
}
