import Foundation

/// 全库搜索（v0.8.36）：把每本书的 `EbookSearchCore.Hit` 合成一条带书 id 的结果。
nonisolated struct EbookLibrarySearchHit: Identifiable, Equatable, Sendable {
    var bookID: UUID
    var bookTitle: String
    var chapterIndex: Int
    var chapterTitle: String
    var snippet: String
    var offset: Int

    var id: String { "\(bookID.uuidString)-\(chapterIndex)-\(offset)" }
}

nonisolated enum EbookLibrarySearchCore {

    /// 每本最多 `perBook` 条、总计最多 `total` 条；保持调用方给的书顺序
    /// （通常已按最近阅读排序）。
    static func merge(_ results: [(bookID: UUID, title: String,
                                   hits: [EbookSearchCore.Hit])],
                      perBook: Int = 3,
                      total: Int = 60) -> [EbookLibrarySearchHit] {
        var out: [EbookLibrarySearchHit] = []
        let bookCap = max(1, perBook)
        let totalCap = max(1, total)
        for entry in results {
            for hit in entry.hits.prefix(bookCap) {
                out.append(EbookLibrarySearchHit(
                    bookID: entry.bookID, bookTitle: entry.title,
                    chapterIndex: hit.chapterIndex, chapterTitle: hit.chapterTitle,
                    snippet: hit.snippet, offset: hit.offset))
                if out.count >= totalCap { return out }
            }
        }
        return out
    }

    /// 按书分组（结果顺序保持）。
    static func grouped(_ hits: [EbookLibrarySearchHit])
        -> [(bookID: UUID, title: String, hits: [EbookLibrarySearchHit])] {
        var groups: [(bookID: UUID, title: String, hits: [EbookLibrarySearchHit])] = []
        for hit in hits {
            if let index = groups.firstIndex(where: { $0.bookID == hit.bookID }) {
                groups[index].hits.append(hit)
            } else {
                groups.append((hit.bookID, hit.bookTitle, [hit]))
            }
        }
        return groups
    }
}
