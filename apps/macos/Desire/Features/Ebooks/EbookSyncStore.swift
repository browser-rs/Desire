import Combine
import Foundation

/// 电子书同步的本地状态（v0.8.37）：书签墓碑、孤儿条目、脏通知。
@MainActor
final class EbookSyncStore: ObservableObject {
    static let shared = EbookSyncStore()

    /// "hash:bookmarkUUID" → 删除时间
    @Published private(set) var pendingBookmarkDeletions: [String: Date] = [:]
    /// 远端书/书签先到、本机还没有同 hash 的书时暂存。
    @Published private(set) var orphanBooks: [String: EbookSyncBookPayload] = [:]
    @Published private(set) var orphanBookmarks: [String: [EbookSyncBookmarkPayload]] = [:]

    private let pendingKey = "ebooks.sync.pendingBookmarkDeletions"
    private let orphanBooksKey = "ebooks.sync.orphanBooks"
    private let orphanBookmarksKey = "ebooks.sync.orphanBookmarks"

    private init() {
        pendingBookmarkDeletions = DiskStore.load([String: Date].self, key: pendingKey) ?? [:]
        orphanBooks = DiskStore.load([String: EbookSyncBookPayload].self,
                                     key: orphanBooksKey) ?? [:]
        orphanBookmarks = DiskStore.load([String: [EbookSyncBookmarkPayload]].self,
                                         key: orphanBookmarksKey) ?? [:]
    }

    private func persistDeletions() {
        DiskStore.save(pendingBookmarkDeletions, key: pendingKey)
    }

    func deletionKey(bookHash: String, bookmarkID: UUID) -> String {
        "\(bookHash.lowercased()):\(bookmarkID.uuidString.lowercased())"
    }

    func noteBookmarkRemoved(bookHash: String, bookmarkID: UUID) {
        pendingBookmarkDeletions[deletionKey(bookHash: bookHash, bookmarkID: bookmarkID)] = Date()
        persistDeletions()
        objectWillChange.send()
    }

    /// 新书签/书签内容变化：只标脏，不记墓碑。
    func bookmarkChanged() {
        objectWillChange.send()
    }

    func clearBookmarkDeletions(keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for key in keys { pendingBookmarkDeletions.removeValue(forKey: key) }
        persistDeletions()
    }

    func saveOrphanBook(_ payload: EbookSyncBookPayload) {
        orphanBooks[payload.hash.lowercased()] = payload
        DiskStore.save(orphanBooks, key: orphanBooksKey)
        objectWillChange.send()
    }

    func saveOrphanBookmark(_ payload: EbookSyncBookmarkPayload) {
        let hash = payload.bookHash.lowercased()
        var items = orphanBookmarks[hash] ?? []
        if let index = items.firstIndex(where: { $0.bookmark.id == payload.bookmark.id }) {
            items[index] = payload
        } else {
            items.append(payload)
        }
        orphanBookmarks[hash] = items
        DiskStore.save(orphanBookmarks, key: orphanBookmarksKey)
        objectWillChange.send()
    }

    func removeOrphanBookmark(bookHash: String, bookmarkID: UUID) {
        let hash = bookHash.lowercased()
        guard var items = orphanBookmarks[hash],
              items.contains(where: { $0.bookmark.id == bookmarkID }) else { return }
        items.removeAll { $0.bookmark.id == bookmarkID }
        if items.isEmpty {
            orphanBookmarks.removeValue(forKey: hash)
        } else {
            orphanBookmarks[hash] = items
        }
        DiskStore.save(orphanBookmarks, key: orphanBookmarksKey)
        objectWillChange.send()
    }


    /// 远端摘录 → 书内高亮（v0.8.37）。只有带完整 locator 的摘录才回显；
    /// 按 id / 章节+偏移+原文去重，避免同一高亮在两端各生成一条。
    func applyRemoteExcerpt(_ excerpt: Excerpt) {
        guard let hash = excerpt.bookHash?.lowercased(),
              let chapter = excerpt.chapterIndex,
              let start = excerpt.startOffset,
              let end = excerpt.endOffset, end > start,
              let book = EbookLibraryStore.shared.books.first(where: {
                  $0.hash.lowercased() == hash
              }) else { return }
        var highlights = EbookHighlightStore.load(book.id)
        if let index = highlights.firstIndex(where: {
            $0.id == excerpt.id
                || ($0.chapterIndex == chapter && $0.startOffset == start
                    && $0.endOffset == end && $0.quote == excerpt.content)
        }) {
            var changed = false
            if highlights[index].note != excerpt.note {
                highlights[index].note = excerpt.note
                changed = true
            }
            if changed {
                EbookHighlightStore.save(highlights, for: book.id)
                NotificationCenter.default.post(
                    name: .ebookHighlightsDidSync, object: book.id)
            }
            return
        }
        highlights.append(EbookHighlight(
            id: excerpt.id, chapterIndex: chapter,
            chapterTitle: excerpt.chapterTitle ?? "Chapter \(chapter + 1)",
            chapterProgress: 0,
            quote: excerpt.content, startOffset: start, endOffset: end,
            color: .yellow, note: excerpt.note, createdAt: excerpt.createdAt))
        EbookHighlightStore.save(highlights, for: book.id)
        NotificationCenter.default.post(
            name: .ebookHighlightsDidSync, object: book.id)
    }

    /// 远端摘录删除 → 删掉由它回显出的书内高亮（本地自建高亮 id 不同，不会误删）。
    func removeRemoteHighlight(excerptID: UUID) {
        for book in EbookLibraryStore.shared.books {
            var highlights = EbookHighlightStore.load(book.id)
            guard highlights.contains(where: { $0.id == excerptID }) else { continue }
            highlights.removeAll { $0.id == excerptID }
            EbookHighlightStore.save(highlights, for: book.id)
            NotificationCenter.default.post(
                name: .ebookHighlightsDidSync, object: book.id)
        }
    }

    /// 书导入后把已同步摘录回显到正文（不依赖 orphan 是否存在）。
    func applySyncedExcerpts(for book: Ebook) {
        let hash = book.hash.lowercased()
        for excerpt in ExcerptStore.shared.excerpts
            where excerpt.bookHash?.lowercased() == hash {
            applyRemoteExcerpt(excerpt)
        }
    }

    /// 新书导入/登记后应用同 hash 的孤儿数据；返回是否改动了本机状态。
    func applyOrphans(for book: Ebook) -> Bool {
        let hash = book.hash.lowercased()
        var changed = false
        if let payload = orphanBooks.removeValue(forKey: hash) {
            changed = EbookLibraryStore.shared.applyRemoteBook(payload, preferRemoteMetadata: true)
            DiskStore.save(orphanBooks, key: orphanBooksKey)
        }
        if let payloads = orphanBookmarks.removeValue(forKey: hash) {
            let local = EbookBookmarkStore.load(book.id)
            let merged = EbookSyncCore.mergeBookmarks(
                local: local,
                remote: payloads,
                deletedIDs: [])
            if merged != local {
                EbookBookmarkStore.save(merged, for: book.id)
                NotificationCenter.default.post(
                    name: .ebookBookmarksDidSync, object: book.id)
                changed = true
            }
            DiskStore.save(orphanBookmarks, key: orphanBookmarksKey)
        }
        applySyncedExcerpts(for: book)
        if changed { objectWillChange.send() }
        return changed
    }
}

extension Notification.Name {
    static let ebookBookmarksDidSync = Notification.Name("ebookBookmarksDidSync")
    static let ebookHighlightsDidSync = Notification.Name("ebookHighlightsDidSync")
}
