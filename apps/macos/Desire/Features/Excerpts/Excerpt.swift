import Foundation

/// 摘录（v0.8.17 融合旗舰）：阅读高亮、PDF 批注、网页划选统一沉淀的
/// 最小单元——来源 + 原文 + 可选备注。Foundation-only，进 tests/run.sh
/// （去重键、Markdown 导出、类型标签）。
nonisolated struct Excerpt: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case readerHighlight
        case pdfAnnotation
        case webSelection
    }

    let id: UUID
    var kind: Kind
    /// 来源标题（页面标题 / PDF 文件名）。
    var title: String
    /// 来源 URL（网页）或文件路径（PDF 本地件）。
    var source: String
    var content: String
    var note: String?
    var createdAt: Date
    /// 同步 LWW 盖戳（编辑/重推推进；与 JobRecord.updatedAt 同语义）。
    var updatedAt: Date

    init(kind: Kind, title: String, source: String, content: String, note: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.source = source
        self.content = content
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 去重键：同来源 + 同内容视为同一条（重复收录 = 刷新时间戳不新增）。
    var dedupeKey: String {
        source + "\u{1f}" + content
    }

    var kindLabel: String {
        switch kind {
        case .readerHighlight: return String(localized: "Reading")
        case .pdfAnnotation: return String(localized: "PDF")
        case .webSelection: return String(localized: "Web")
        }
    }

    /// 关键字命中（标题/内容/备注/来源，大小写不敏感）。
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q)
            || content.localizedCaseInsensitiveContains(q)
            || source.localizedCaseInsensitiveContains(q)
            || (note?.localizedCaseInsensitiveContains(q) ?? false)
    }

    /// Markdown 笔记本按来源分节的一节。
    nonisolated static func markdownSection(title: String, source: String, items: [Excerpt]) -> String {
        guard !items.isEmpty else { return "" }
        var out = "## \(title)\n\n"
        out += "> \(source)\n\n"
        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) {
            for line in item.content.split(separator: "\n", omittingEmptySubsequences: false) {
                out += "> \(line)\n"
            }
            if let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                out += "\n**\(note)**\n"
            }
            out += "\n"
        }
        return out
    }
}
