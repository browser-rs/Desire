import Foundation

/// 阅读高亮（v0.7.29）：选中文本 + 前后文锚点，按页面 URL 持久化。
/// 锚点用 `quote + prefix + suffix`（类似 Web Annotation 的 TextQuoteSelector），
/// 字号/主题变化导致 DOM 重建时仍能定位；匹配逻辑是纯函数（进 harness）。
nonisolated struct ReaderHighlight: Codable, Identifiable, Equatable {
    let id: UUID
    var url: String
    var quote: String
    var prefix: String
    var suffix: String
    var color: Color
    var note: String?
    var createdAt: Date

    enum Color: String, Codable, CaseIterable {
        case yellow, green, blue, pink

        var title: String {
            switch self {
            case .yellow: return String(localized: "Yellow")
            case .green: return String(localized: "Green")
            case .blue: return String(localized: "Blue")
            case .pink: return String(localized: "Pink")
            }
        }
    }

    init(id: UUID = UUID(), url: String, quote: String,
         prefix: String = "", suffix: String = "",
         color: Color = .yellow, note: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.color = color
        self.note = note
        self.createdAt = createdAt
    }
}

nonisolated enum ReaderHighlightAnchor {
    static let contextLimit = 40

    /// 在纯文本里定位 quote（返回字符偏移区间）。
    /// 优先级：prefix 紧邻 + suffix 匹配 → prefix 紧邻 → 唯一 quote。
    static func locate(quote: String, prefix: String, suffix: String,
                       in text: String) -> Range<Int>? {
        let q = Array(quote)
        guard !q.isEmpty else { return nil }
        let chars = Array(text)
        guard chars.count >= q.count else { return nil }

        func matches(_ index: Int) -> Bool {
            guard index >= 0, index + q.count <= chars.count else { return false }
            return Array(chars[index..<index + q.count]) == q
        }
        func allOccurrences() -> [Int] {
            guard chars.count >= q.count else { return [] }
            var found: [Int] = []
            for index in 0...(chars.count - q.count) where matches(index) {
                found.append(index)
            }
            return found
        }

        let p = Array(prefix)
        let s = Array(suffix)
        var candidates: [Int]
        if p.isEmpty {
            candidates = allOccurrences()
        } else {
            candidates = []
            guard chars.count >= p.count + q.count else { return nil }
            for index in 0...(chars.count - p.count - q.count) {
                if Array(chars[index..<index + p.count]) == p, matches(index + p.count) {
                    candidates.append(index + p.count)
                }
            }
        }
        if !s.isEmpty {
            for candidate in candidates
            where candidate + q.count + s.count <= chars.count {
                if Array(chars[candidate + q.count..<candidate + q.count + s.count]) == s {
                    return candidate..<(candidate + q.count)
                }
            }
        }
        if let first = candidates.first { return first..<(first + q.count) }
        // prefix 不匹配时退回全文首次出现（页面轻微改动仍有机会命中）。
        if !p.isEmpty, let first = allOccurrences().first {
            return first..<(first + q.count)
        }
        return nil
    }

    /// 导出 Markdown：每条高亮一段引用 + 备注。
    static func markdown(url: String, highlights: [ReaderHighlight]) -> String {
        guard !highlights.isEmpty else { return "" }
        var lines = ["# Highlights", "", url, ""]
        for (index, item) in highlights.enumerated() {
            lines.append("## \(index + 1)")
            lines.append("> " + item.quote.replacingOccurrences(of: "\n", with: "\n> "))
            if let note = item.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("")
                lines.append(note)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
