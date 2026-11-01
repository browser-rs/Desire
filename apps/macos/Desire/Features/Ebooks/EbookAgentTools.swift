import Foundation

/// 电子书 Agent 工具（v0.8.34 批次四）：书库列表、按章节读正文、搜书、目录。
@MainActor
enum EbookAgentTools {

    static func listBooks() -> String {
        let books = EbookLibraryStore.shared.books.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
        guard !books.isEmpty else {
            return "No ebooks in the library. Import an EPUB or TXT first."
        }
        return books.map { book in
            let progress = Int((book.progress * 100).rounded())
            return "\(book.id.uuidString) | \(book.title) | \(book.authorOrUnknown) | \(book.format.displayName) | \(progress)% | \(book.chapterCount) chapters"
        }.joined(separator: "\n")
    }

    static func readBook(book: String?, chapters: String?, maxChars: Int) async -> String {
        guard let selected = resolve(book) else { return fail("no matching ebook") }
        do {
            let loaded = try await EbookContentLoader.load(
                book: selected, root: EbookLibraryStore.shared.rootURL)
            let indices = chapterIndices(chapters, count: loaded.chapters.count)
            guard !indices.isEmpty else { return fail("chapter range is empty") }
            let cap = min(max(maxChars, 500), 40_000)
            var output = "# \(loaded.title)"
            if !loaded.author.isEmpty { output += " — \(loaded.author)" }
            output += "\n\n"
            var truncated = false
            for index in indices {
                guard loaded.chapters.indices.contains(index) else { continue }
                let chapter = loaded.chapters[index]
                var block = "[ch\(index + 1)] \(chapter.title)\n\(chapter.text)\n\n"
                if output.count + block.count > cap {
                    let remaining = max(0, cap - output.count)
                    if remaining > 0 { block = String(block.prefix(remaining)) }
                    output += block
                    truncated = true
                    break
                }
                output += block
            }
            if truncated { output += "\n[truncated at \(cap) characters]" }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    static func searchBook(book: String?, query: String, limit: Int) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fail("query is empty") }
        guard let selected = resolve(book) else { return fail("no matching ebook") }
        do {
            let loaded = try await EbookContentLoader.load(
                book: selected, root: EbookLibraryStore.shared.rootURL)
            let hits = EbookSearchCore.search(
                query: trimmed, chapters: loaded.chapters,
                perChapter: 3, limit: min(max(limit, 1), 100))
            guard !hits.isEmpty else { return "No matches for \"\(trimmed)\"." }
            return hits.map {
                "[ch\($0.chapterIndex + 1)] \($0.chapterTitle)\n\($0.snippet)"
            }.joined(separator: "\n\n")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    static func outline(book: String?) async -> String {
        guard let selected = resolve(book) else { return fail("no matching ebook") }
        do {
            let loaded = try await EbookContentLoader.load(
                book: selected, root: EbookLibraryStore.shared.rootURL)
            guard !loaded.toc.isEmpty else { return "This ebook has no table of contents." }
            return loaded.toc.map { item in
                String(repeating: "  ", count: max(0, item.level))
                    + "- \(item.title)"
                    + (item.chapterIndex.map { " [ch\($0 + 1)]" } ?? "")
            }.joined(separator: "\n")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: - 解析

    private static func resolve(_ raw: String?) -> Ebook? {
        let books = EbookLibraryStore.shared.books
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return books.sorted {
                ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
            }.first
        }
        let needle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let id = UUID(uuidString: raw),
           let exact = books.first(where: { $0.id == id }) {
            return exact
        }
        return books.first {
            $0.id.uuidString.lowercased().hasPrefix(needle)
                || $0.title.lowercased().contains(needle)
                || $0.fileName.lowercased().contains(needle)
        }
    }

    /// "1-3,5"（1 基）→ 0 基章节下标；nil/空 = 全部。
    private static func chapterIndices(_ raw: String?, count: Int) -> [Int] {
        let text = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.lowercased() == "all" {
            return Array(0..<max(0, count))
        }
        guard let parsed = PDFToolCore.parsePageNumbers(text, pageCount: count) else {
            return []
        }
        return parsed.map { $0 - 1 }
    }

    private static func fail(_ message: String) -> String {
        "Error: " + message
    }
}
