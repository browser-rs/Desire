import Foundation

/// 电子书内容加载（v0.8.34 批次四）：把 EPUB/TXT 读成纯文本章节，
/// 供 Agent 工具与书内搜索复用。文件读取在后台任务里跑。
nonisolated enum EbookContentLoader {

    struct Loaded: Sendable {
        var title: String
        var author: String
        var chapters: [EbookSearchCore.ChapterText]
        var toc: [EbookCore.TOCItem]
    }

    enum LoadError: LocalizedError {
        case cannotOpen
        case empty

        var errorDescription: String? {
            switch self {
            case .cannotOpen:
                return String(localized: "Could not open this ebook.")
            case .empty:
                return String(localized: "This ebook has no readable text.")
            }
        }
    }

    static func load(book: Ebook, root: URL) async throws -> Loaded {
        try await Task.detached(priority: .userInitiated) {
            let directory = root.appendingPathComponent(book.containerDirectory,
                                                        isDirectory: true)
            switch book.format {
            case .epub:
                return try loadEPUB(directory: directory, book: book)
            case .txt:
                return try loadTXT(directory: directory, book: book)
            case .markdown:
                return try loadMarkdown(directory: directory, book: book)
            case .html:
                return try loadHTML(directory: directory, book: book)
            default:
                throw LoadError.cannotOpen
            }
        }.value
    }

    private static func loadEPUB(directory: URL, book: Ebook) throws -> Loaded {
        let container = directory.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: container),
              let rootfile = EbookCore.rootfilePath(container: containerData) else {
            throw LoadError.cannotOpen
        }
        guard let opfData = try? Data(contentsOf: directory.appendingPathComponent(rootfile)),
              let package = EbookCore.parseOPF(opfData, opfPath: rootfile) else {
            throw LoadError.cannotOpen
        }
        var tocItems: [EbookCore.TOCItem] = []
        if let navHref = package.navHref,
           let data = try? Data(contentsOf: directory.appendingPathComponent(navHref)) {
            tocItems = EbookCore.parseNav(data, opfDirectory: package.opfDirectory)
        }
        if tocItems.isEmpty, let ncxHref = package.ncxHref,
           let data = try? Data(contentsOf: directory.appendingPathComponent(ncxHref)) {
            tocItems = EbookCore.parseNCX(data, opfDirectory: package.opfDirectory)
        }
        let chapters: [EbookSearchCore.ChapterText] = package.chapters.compactMap { chapter in
            let url = directory.appendingPathComponent(chapter.href)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) ?? ""
            return EbookSearchCore.ChapterText(
                index: chapter.index, title: chapter.title,
                text: EbookSearchCore.plainText(fromHTML: html))
        }
        guard !chapters.isEmpty else { throw LoadError.empty }
        if tocItems.isEmpty {
            tocItems = chapters.map {
                EbookCore.TOCItem(title: $0.title, href: "", level: 0,
                                  chapterIndex: $0.index)
            }
        }
        return Loaded(title: book.title, author: book.author,
                      chapters: chapters,
                      toc: EbookCore.applyingTOC(tocItems, to: package.chapters))
    }

    private static func loadTXT(directory: URL, book: Ebook) throws -> Loaded {
        let url = directory.appendingPathComponent(book.fileName)
        guard let data = try? Data(contentsOf: url),
              let text = EbookCore.decodeTXT(data) else {
            throw LoadError.cannotOpen
        }
        let chapters = EbookCore.splitTXT(text)
        guard !chapters.isEmpty else { throw LoadError.empty }
        let mapped = chapters.map {
            EbookSearchCore.ChapterText(index: $0.index, title: $0.title, text: $0.text)
        }
        let toc = mapped.map {
            EbookCore.TOCItem(title: $0.title, href: "", level: 0,
                              chapterIndex: $0.index)
        }
        return Loaded(title: book.title, author: book.author, chapters: mapped, toc: toc)
    }

    private static func loadMarkdown(directory: URL, book: Ebook) throws -> Loaded {
        let url = directory.appendingPathComponent(book.fileName)
        guard let data = try? Data(contentsOf: url),
              let text = EbookCore.decodeTXT(data) else {
            throw LoadError.cannotOpen
        }
        let chapters = EbookCore.splitMarkdown(text)
        guard !chapters.isEmpty else { throw LoadError.empty }
        let mapped = chapters.map {
            EbookSearchCore.ChapterText(index: $0.index, title: $0.title, text: $0.text)
        }
        let toc = mapped.map {
            EbookCore.TOCItem(title: $0.title, href: "", level: 0,
                              chapterIndex: $0.index)
        }
        return Loaded(title: book.title, author: book.author, chapters: mapped, toc: toc)
    }

    private static func loadHTML(directory: URL, book: Ebook) throws -> Loaded {
        let url = directory.appendingPathComponent(book.fileName)
        guard let data = try? Data(contentsOf: url),
              let text = EbookCore.decodeTXT(data) else {
            throw LoadError.cannotOpen
        }
        let plain = EbookSearchCore.plainText(fromHTML: text)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LoadError.empty
        }
        let chapters = [EbookSearchCore.ChapterText(
            index: 0, title: book.title, text: plain)]
        let toc = [EbookCore.TOCItem(title: book.title, href: book.fileName, level: 0,
                                     chapterIndex: 0)]
        return Loaded(title: book.title, author: book.author, chapters: chapters, toc: toc)
    }
}
