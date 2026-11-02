import Foundation

/// 整章翻译缓存（v0.8.36）：按书存 `ebook.translations.<bookID>`。
nonisolated enum EbookTranslationStore {

    static func key(for bookID: UUID) -> String {
        "ebook.translations.\(bookID.uuidString)"
    }

    static func load(_ bookID: UUID) -> EbookTranslationCache {
        DiskStore.load(EbookTranslationCache.self, key: key(for: bookID))
            ?? EbookTranslationCache()
    }

    static func save(_ cache: EbookTranslationCache, for bookID: UUID) {
        DiskStore.save(cache, key: key(for: bookID))
    }
}
