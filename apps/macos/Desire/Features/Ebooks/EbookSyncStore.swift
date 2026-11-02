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

    /// 新书导入/登记后应用同 hash 的孤儿数据；返回是否改动了本机状态。
    func applyOrphans(for book: Ebook) -> Bool {
        let hash = book.hash.lowercased()
        var changed = false
        if let payload = orphanBooks.removeValue(forKey: hash) {
            changed = EbookLibraryStore.shared.applyRemoteBook(payload)
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
        if changed { objectWillChange.send() }
        return changed
    }
}

extension Notification.Name {
    static let ebookBookmarksDidSync = Notification.Name("ebookBookmarksDidSync")
}
