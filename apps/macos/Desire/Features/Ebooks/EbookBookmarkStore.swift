import Foundation

/// 书签按书持久化（v0.8.37 抽出）：阅读器与同步适配器共用同一份文件。
nonisolated enum EbookBookmarkStore {
    static func key(for bookID: UUID) -> String {
        "ebook.bookmarks.\(bookID.uuidString)"
    }

    static func load(_ bookID: UUID) -> [EbookBookmark] {
        DiskStore.load([EbookBookmark].self, key: key(for: bookID)) ?? []
    }

    static func save(_ bookmarks: [EbookBookmark], for bookID: UUID) {
        DiskStore.save(bookmarks, key: key(for: bookID))
    }
}
