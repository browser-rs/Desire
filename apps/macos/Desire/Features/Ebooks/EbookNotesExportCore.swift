import Foundation

/// 书内笔记导出（v0.8.35）：纯 Foundation，进 tests/run.sh。
/// 输出按「书 → 章 → 位置」排序的 Markdown，供 NSSavePanel 落盘或复制。
nonisolated enum EbookNotesExportCore {

    /// 单本书。
    static func markdown(title: String, author: String, highlights: [EbookHighlight]) -> String {
        var out = "# \(title)\n\n"
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !author.isEmpty { out += "_\(author)_\n\n" }
        out += "> \(highlights.count) highlight(s)\n\n"
        out += sections(highlights, chapterHeadingLevel: 2)
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// 多本书（导出全部）。
    static func markdown(books: [(title: String, author: String, highlights: [EbookHighlight])]) -> String {
        let nonEmpty = books.filter { !$0.highlights.isEmpty }
        let total = nonEmpty.reduce(0) { $0 + $1.highlights.count }
        var out = "# Book Notes\n\n"
        out += "> \(total) highlight(s) · \(nonEmpty.count) book(s)\n\n"
        for book in nonEmpty {
            out += "## \(book.title)\n\n"
            let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty { out += "_\(author)_\n\n" }
            out += sections(book.highlights, chapterHeadingLevel: 3)
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// 文件名安全化：去掉路径分隔符/通配符/引号，压空白，限长。
    static func filename(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let banned: Set<Character> = ["/", "\\", ":", "?", "%", "*", "|", "\"", "<", ">", "\n", "\r", "\t"]
        var chars: [Character] = []
        for character in trimmed {
            chars.append(banned.contains(character) ? "-" : character)
        }
        var name = String(chars)
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        if name.count > 80 { name = String(name.prefix(80)) }
        if name.isEmpty { name = "book" }
        return name + "-notes.md"
    }

    // MARK: - 内部分节

    private static func sections(_ highlights: [EbookHighlight],
                                 chapterHeadingLevel: Int) -> String {
        let grouped = Dictionary(grouping: highlights, by: { $0.chapterIndex })
        let ordered = grouped.keys.sorted()
        var out = ""
        for chapterIndex in ordered {
            let items = (grouped[chapterIndex] ?? []).sorted {
                if $0.startOffset != $1.startOffset { return $0.startOffset < $1.startOffset }
                return $0.createdAt < $1.createdAt
            }
            let title = items.first?.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let heading = title.isEmpty ? "Chapter \(chapterIndex + 1)" : title
            out += String(repeating: "#", count: max(1, chapterHeadingLevel)) + " \(heading)\n\n"
            for item in items {
                for line in item.quote.split(separator: "\n", omittingEmptySubsequences: false) {
                    out += "> \(line)\n"
                }
                if let note = item.trimmedNote {
                    out += "\n**\(note)**\n"
                }
                out += "\n*\(dateString(item.createdAt))*\n\n"
            }
        }
        return out
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
