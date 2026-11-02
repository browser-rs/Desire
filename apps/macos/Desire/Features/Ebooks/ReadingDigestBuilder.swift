import Foundation

/// 从本地 store 汇总阅读摘要（v0.8.36）：统计页与 Agent 工具共用。
@MainActor
enum ReadingDigestBuilder {

    static func markdown(daysBack: Int = 7) -> String {
        let period = max(1, daysBack)
        let days = ReadingStatsStore.shared.recentDays(period)
        let books = EbookLibraryStore.shared.books
        let cutoff = Calendar.current.date(byAdding: .day, value: -period, to: Date())
            ?? Date.distantPast
        var highlights: [ReadingDigestHighlight] = []
        for book in books {
            for highlight in EbookHighlightStore.load(book.id) where highlight.createdAt >= cutoff {
                highlights.append(ReadingDigestHighlight(
                    bookTitle: book.title,
                    chapterTitle: highlight.chapterTitle,
                    quote: highlight.quote,
                    note: highlight.trimmedNote,
                    createdAt: highlight.createdAt))
            }
        }
        return ReadingDigestCore.markdown(
            days: days, books: books, highlights: highlights,
            daysBack: period)
    }
}
