import Foundation

/// 全库搜索执行器（v0.8.36）：串行加载每本书的章节文本，逐书搜索。
/// 最多 50 本、可取消；UI 与 Agent 工具共用。
@MainActor
enum EbookLibrarySearchEngine {

    static func search(query: String, books: [Ebook], maxBooks: Int = 50,
                       perBook: Int = 3, total: Int = 60,
                       progress: ((_ done: Int, _ total: Int) -> Void)? = nil)
        async -> [EbookLibrarySearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let selected = Array(books.prefix(max(1, maxBooks)))
        let root = EbookLibraryStore.shared.rootURL
        var results: [(bookID: UUID, title: String, hits: [EbookSearchCore.Hit])] = []
        for (index, book) in selected.enumerated() {
            if Task.isCancelled { break }
            if let loaded = try? await EbookContentLoader.load(book: book, root: root) {
                let hits = EbookSearchCore.search(
                    query: needle, chapters: loaded.chapters,
                    perChapter: perBook, limit: perBook)
                if !hits.isEmpty {
                    results.append((book.id, book.title, hits))
                }
            }
            progress?(index + 1, selected.count)
        }
        return EbookLibrarySearchCore.merge(results, perBook: perBook, total: total)
    }
}
