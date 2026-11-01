import Foundation

/// 书内高亮的按书持久化（v0.8.35）：与书签同一套 DiskStore 口径，
/// key = `ebook.highlights.<bookID>`。
nonisolated enum EbookHighlightStore {

    static func key(for bookID: UUID) -> String {
        "ebook.highlights.\(bookID.uuidString)"
    }

    static func load(_ bookID: UUID) -> [EbookHighlight] {
        DiskStore.load([EbookHighlight].self, key: key(for: bookID)) ?? []
    }

    static func save(_ highlights: [EbookHighlight], for bookID: UUID) {
        DiskStore.save(highlights, key: key(for: bookID))
    }
}
