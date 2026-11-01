import Combine
import Foundation

/// 当前阅读中的书（v0.8.35）：给 Agent 系统提示词一层 `<current_book>`，
/// 让"总结这一章 / 这本书讲了什么"无需再指定书名。
@MainActor
final class EbookReaderSession: ObservableObject {
    static let shared = EbookReaderSession()

    @Published private(set) var bookID: UUID?
    @Published private(set) var title = ""
    @Published private(set) var author = ""
    @Published private(set) var chapterIndex = 0
    @Published private(set) var chapterCount = 1
    @Published private(set) var chapterTitle = ""
    @Published private(set) var progress: Double = 0

    private init() {}

    func update(book: Ebook, chapterIndex: Int, chapterTitle: String,
                chapterCount: Int, progress: Double) {
        bookID = book.id
        title = book.title
        author = book.author
        self.chapterIndex = max(0, chapterIndex)
        self.chapterCount = max(1, chapterCount)
        self.chapterTitle = chapterTitle
        self.progress = min(max(progress, 0), 1)
    }

    func clear(bookID: UUID?) {
        guard self.bookID == bookID else { return }
        self.bookID = nil
        title = ""
        author = ""
        chapterIndex = 0
        chapterCount = 1
        chapterTitle = ""
        progress = 0
    }

    /// 系统提示词用的一行段（nil = 没在读书）。
    var promptSummary: String? {
        guard let bookID else { return nil }
        var lines = ["Book: \(title)"]
        if !author.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Author: \(author)")
        }
        lines.append("Chapter \(chapterIndex + 1)/\(chapterCount): \(chapterTitle)")
        lines.append("Progress: \(Int((progress * 100).rounded()))%")
        lines.append("Book id: \(bookID.uuidString)")
        return lines.joined(separator: "\n")
    }
}
