import Foundation
import WebKit

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

    /// 触发一次同步并返回各域结果（v0.8.37）。
    static func syncNow() async -> String {
        guard let sync = AppState.live?.syncStore else {
            return fail("sync is unavailable")
        }
        guard case .signedIn = sync.authState else {
            return "Not signed in. Sign in from Settings ▸ Sync first."
        }
        await sync.syncNow()
        return "Synced.\n" + syncStatusText(sync)
    }

    /// 登录态/各域状态/ebooks 孤儿/阅读进度摘要。
    static func syncStatus() -> String {
        guard let sync = AppState.live?.syncStore else {
            return fail("sync is unavailable")
        }
        return syncStatusText(sync)
    }

    private static func syncStatusText(_ sync: SyncStore) -> String {
        var lines: [String] = []
        switch sync.authState {
        case .signedOut:
            lines.append("Account: signed out")
        case .signedIn(let username):
            lines.append("Account: \(username)")
        }
        if let last = sync.lastSyncAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            lines.append("Last sync: \(formatter.string(from: last))")
        } else {
            lines.append("Last sync: never")
        }
        if let error = sync.lastError, !error.isEmpty {
            lines.append("Last error: \(error)")
        }
        let failed = SyncDomain.allCases.compactMap { domain -> String? in
            guard case .failed(let message)? = sync.domainStatus[domain] else { return nil }
            return "  - \(domain.displayName): \(message)"
        }
        if failed.isEmpty {
            lines.append("Domains: all enabled domains are OK")
        } else {
            lines.append("Domains with errors:")
            lines.append(contentsOf: failed)
        }
        if case .failed(let message)? = sync.domainStatus[.ebooks] {
            lines.append("Books sync: \(message)")
        }
        let orphanCount = EbookSyncStore.shared.orphanBooks.count
            + EbookSyncStore.shared.orphanBookmarks.values.reduce(0) { $0 + $1.count }
        lines.append("Book sync: \(orphanCount) orphan item(s), "
            + "\(EbookSyncStore.shared.pendingBookmarkDeletions.count) bookmark deletion(s) pending")
        let books = EbookLibraryStore.shared.books
            .filter { $0.progress > 0 }
            .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
            .prefix(8)
        if !books.isEmpty {
            lines.append("Reading progress:")
            for book in books {
                lines.append("  - \(book.title): \(Int((book.progress * 100).rounded()))%"
                    + " (ch \(book.lastChapterIndex + 1)/\(max(1, book.chapterCount)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 全库正文搜索（v0.8.36）：跨书写作者的所有本地书，结果按书分组。
    static func searchLibrary(query: String, limit: Int) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fail("query is empty") }
        let books = EbookLibraryStore.shared.books.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
        let hits = await EbookLibrarySearchEngine.search(
            query: trimmed, books: books, maxBooks: 50, perBook: 3,
            total: min(max(limit, 1), 60))
        guard !hits.isEmpty else {
            return "No matches for \"\(trimmed)\" in any book."
        }
        let groups = EbookLibrarySearchCore.grouped(hits)
        return groups.map { group in
            "# \(group.title)\n" + group.hits.map {
                "[ch\($0.chapterIndex + 1)] \($0.chapterTitle)\n\($0.snippet)"
            }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    /// 阅读回顾（v0.8.36）：本地统计 + 最近笔记的 Markdown。
    static func readingDigest(days: Int) -> String {
        ReadingDigestBuilder.markdown(daysBack: max(1, min(days, 90)))
    }

    // MARK: - v0.8.35

    static func openBook(book: String?, chapter: Int?) -> String {
        guard let selected = resolve(book) else { return fail("no matching ebook") }
        guard let tab = TabSessionCoordinator.shared.activeTabManager?.selectedTab else {
            return fail("no active tab")
        }
        let count = max(1, selected.chapterCount)
        let target = max(0, min(chapter ?? selected.lastChapterIndex, count - 1))
        let raw = "desire://books/\(selected.id.uuidString)"
            + (chapter == nil ? "" : "?chapter=\(target)")
        guard let destination = InternalPages.parse(raw) else {
            return fail("could not open this book")
        }
        InternalPages.open(destination, in: tab)
        return "Opened \"\(selected.title)\" at chapter \(target + 1)/\(count)."
    }

    static func listBookHighlights(book: String?, limit: Int) -> String {
        guard let selected = resolve(book) else { return fail("no matching ebook") }
        let items = EbookHighlightStore.load(selected.id).sorted {
            if $0.chapterIndex != $1.chapterIndex { return $0.chapterIndex < $1.chapterIndex }
            if $0.startOffset != $1.startOffset { return $0.startOffset < $1.startOffset }
            return $0.createdAt < $1.createdAt
        }
        guard !items.isEmpty else {
            return "No highlights or notes in \"\(selected.title)\"."
        }
        let cap = min(max(limit, 1), 100)
        return items.prefix(cap).map { item in
            var block = "[ch\(item.chapterIndex + 1)] \(item.chapterTitle)\n> \(item.quote)"
            if let note = item.trimmedNote { block += "\nNote: \(note)" }
            return block
        }.joined(separator: "\n\n")
    }

    /// 把当前标签页的阅读正文存成书（页面需先在当前标签打开）。
    static func saveWebPageToLibrary() async -> String {
        guard let tab = TabSessionCoordinator.shared.activeTabManager?.selectedTab else {
            return fail("no active tab")
        }
        let browser = tab.browser
        let currentURL = browser.webView.url?.absoluteString ?? ""
        if browser.readerContent.isEmpty || browser.readerBaseURLString != currentURL {
            _ = try? await browser.webView.evaluateJavaScript("window._desireReader()")
            var waited = 0
            while (browser.readerContent.isEmpty
                   || browser.readerBaseURLString != currentURL) && waited < 60 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
        }
        guard !browser.readerContent.isEmpty else {
            return fail("could not extract article text from the current page")
        }
        let pageTitle = browser.webView.title ?? ""
        let title = browser.readerTitle.isEmpty
            ? (pageTitle.isEmpty ? String(localized: "Web page") : pageTitle)
            : browser.readerTitle
        let base = URL(string: browser.readerBaseURLString)
        do {
            let result = try await EbookWebBookImporter.importArticle(
                title: title, html: browser.readerContent, baseURL: base)
            if result.existed {
                return "This page is already in the library: \"\(result.book.title)\" (\(result.book.id.uuidString))."
            }
            return "Saved \"\(result.book.title)\" to the library (\(result.imageCount) image(s) "
                + "localized, \(result.failedImages) failed). Book id: \(result.book.id.uuidString)."
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// 保存一段章节级笔记/摘要到摘录库（不回锚到正文，避免伪造 quote）。
    static func addBookNote(book: String?, chapter: Int?, content: String) -> String {
        guard let selected = resolve(book) else { return fail("no matching ebook") }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fail("content is empty") }
        let count = max(1, selected.chapterCount)
        let chapterIndex = max(0, min((chapter ?? 1) - 1, count - 1))
        let root = EbookImporter.rootDirectory
            .appendingPathComponent(selected.containerDirectory, isDirectory: true)
        let added = ExcerptStore.shared.add(
            kind: .readerHighlight,
            title: "\(selected.title) · Chapter \(chapterIndex + 1)",
            source: root.path,
            content: text,
            note: "AI summary")
        return added
            ? "Saved the note to Excerpts (\(selected.title), chapter \(chapterIndex + 1))."
            : "This note is already in Excerpts."
    }

    // MARK: - 解析

    private static func resolve(_ raw: String?) -> Ebook? {
        let books = EbookLibraryStore.shared.books
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            if let current = EbookReaderSession.shared.bookID,
               let book = books.first(where: { $0.id == current }) {
                return book
            }
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
