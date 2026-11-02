import Combine
import Foundation

/// 电子书库（v0.8.34）：导入去重、书架索引持久化、阅读进度。
@MainActor
final class EbookLibraryStore: ObservableObject {
    static let shared = EbookLibraryStore()

    @Published private(set) var books: [Ebook] = []

    nonisolated static let diskKey = "ebooks.library"
    var rootURL: URL { EbookImporter.rootDirectory }

    private init() {
        books = DiskStore.load([Ebook].self, key: Self.diskKey) ?? []
    }

    func book(id: UUID) -> Ebook? {
        books.first { $0.id == id }
    }

    /// 导入；同 SHA-256 已存在时直接返回旧条目并更新最近打开时间。
    func importBook(at url: URL) async throws -> Ebook {
        let hash = try await Task.detached(priority: .userInitiated) {
            try EbookImporter.hashFile(at: url)
        }.value
        if let existing = books.first(where: { $0.hash == hash }) {
            touch(existing.id)
            return existing
        }
        let book = try await Task.detached(priority: .userInitiated) {
            try await EbookImporter.importBook(at: url, hash: hash)
        }.value
        books.insert(book, at: 0)
        save()
        return book
    }

    func touch(_ id: UUID) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].lastOpenedAt = Date()
        save()
    }

    func setFavorite(_ id: UUID, _ value: Bool) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].isFavorite = value
        save()
    }

    func setCollection(_ id: UUID, _ name: String?) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        books[index].collection = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    func rename(_ id: UUID, title: String, author: String) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { books[index].title = trimmedTitle }
        books[index].author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    var collections: [String] {
        Array(Set(books.compactMap(\.collectionName))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// 直接登记一本已写好书库目录的书（v0.8.35 网页存书用）。
    func register(_ book: Ebook) {
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
        } else if let index = books.firstIndex(where: { $0.hash == book.hash }) {
            books[index].lastOpenedAt = Date()
        } else {
            books.insert(book, at: 0)
        }
        save()
    }

    func updateProgress(_ id: UUID, chapterIndex: Int, chapterProgress: Double,
                        overall: Double) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].lastChapterIndex = max(0, chapterIndex)
        books[index].chapterProgress = min(max(chapterProgress, 0), 1)
        books[index].progress = min(max(overall, 0), 1)
        books[index].lastOpenedAt = Date()
        save()
    }

    func remove(_ id: UUID, deleteFiles: Bool) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        let book = books.remove(at: index)
        if deleteFiles {
            let directory = rootURL.appendingPathComponent(book.containerDirectory,
                                                           isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
        DiskStore.remove(key: "ebook.bookmarks.\(book.id.uuidString)")
        DiskStore.remove(key: EbookHighlightStore.key(for: book.id))
        DiskStore.remove(key: EbookTranslationStore.key(for: book.id))
        save()
    }

    func coverURL(for book: Ebook) -> URL? {
        guard let coverPath = book.coverPath else { return nil }
        return rootURL
            .appendingPathComponent(book.containerDirectory, isDirectory: true)
            .appendingPathComponent(coverPath)
    }

    func contentURL(for book: Ebook) -> URL {
        rootURL
            .appendingPathComponent(book.containerDirectory, isDirectory: true)
            .appendingPathComponent(book.fileName)
    }

    private func save() {
        DiskStore.save(books, key: Self.diskKey)
    }
}
