import Foundation

/// 阅读摘要（v0.8.36）：统计 + 书进度 + 最近笔记 → Markdown。Foundation-only，进 harness。
nonisolated struct ReadingDigestHighlight: Equatable, Sendable {
    var bookTitle: String
    var chapterTitle: String
    var quote: String
    var note: String?
    var createdAt: Date
}

nonisolated enum ReadingDigestCore {

    static func markdown(days: [(date: Date, seconds: Int)],
                         books: [Ebook],
                         highlights: [ReadingDigestHighlight],
                         daysBack: Int = 7,
                         now: Date = Date()) -> String {
        let period = max(1, daysBack)
        let totalSeconds = days.reduce(0) { $0 + $1.seconds }
        let cutoff = Calendar.current.date(byAdding: .day, value: -period, to: now)
            ?? now.addingTimeInterval(-Double(period) * 86_400)
        let active = books.filter { book in
            if let opened = book.lastOpenedAt { return opened >= cutoff }
            return book.addedAt >= cutoff
        }.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
        let recent = highlights
            .filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }

        guard totalSeconds > 0 || !active.isEmpty || !recent.isEmpty else {
            return "# Reading Review\n\nNo reading activity in the last \(period) days."
        }

        var out = "# Reading Review\n\n"
        out += "> Last \(period) days · \(duration(totalSeconds)) · "
        out += "\(active.count) book(s) · \(recent.count) highlight(s)\n\n"

        if !active.isEmpty {
            out += "## Books\n\n"
            for book in active.prefix(8) {
                let percent = Int((book.progress * 100).rounded())
                out += "- **\(book.title)** — \(percent)%"
                if !book.author.isEmpty { out += " · \(book.author)" }
                out += "\n"
            }
            out += "\n"
        }

        if !recent.isEmpty {
            out += "## Recent highlights\n\n"
            for item in recent.prefix(12) {
                out += "- **\(item.bookTitle)** · \(item.chapterTitle)\n"
                out += "  > \(item.quote)\n"
                if let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !note.isEmpty {
                    out += "  Note: \(note)\n"
                }
            }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(0, seconds))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
