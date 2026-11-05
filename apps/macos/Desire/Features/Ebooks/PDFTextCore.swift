import Foundation

/// PDF 文本层纯逻辑（v0.8.44 批 2）：段落切分、全文搜索、页锚点。
/// Foundation-only，进 tests/run.sh。PDFKit 的 `PDFPage.string` 在 app 侧
/// 按页喂进来；本核心只管"文本 → 可朗读/可搜索的段落序列"。
nonisolated enum PDFTextCore {

    struct PageText: Sendable, Equatable {
        var index: Int
        var text: String
    }

    /// 朗读/翻译的段落单元：带页锚点（段落 ↔ 页面一一对应，朗读跟随时跳页）。
    struct Paragraph: Sendable, Equatable, Identifiable {
        var id: Int
        var pageIndex: Int
        var text: String
    }

    /// 单段上限（字符）：超长段按句边界切成多段——朗读段落太长没法跳，
    /// 翻译批也容易超限。
    static let maxParagraphLength = 600

    /// 页文本 → 段落序列。启发式：
    /// ① 空行分段；无空行的页整页算一段；
    /// ② 段内行合并成一句（PDF 折行是版面产物，不是换段）；
    /// ③ 超过 maxParagraphLength 的段按句末标点（。！？.!?）切段。
    static func paragraphs(fromPage page: PageText) -> [Paragraph] {
        let lines = page.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // 空行分组
        var groups: [String] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty {
                    groups.append(current.joined(separator: " "))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            groups.append(current.joined(separator: " "))
        }
        groups = groups
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // 无空行退化：整页一段（groups 只有 0 或 1 个元素时已是该语义）
        // 超长段按句边界切
        var pieces: [String] = []
        for group in groups {
            pieces.append(contentsOf: splitLong(group))
        }
        return pieces.map { Paragraph(id: 0, pageIndex: page.index, text: $0) }
    }

    /// 多页组装成全书段落序列（id 连续 0 起——逐段朗读的索引语义）。
    static func paragraphs(fromPages pages: [PageText]) -> [Paragraph] {
        var result: [Paragraph] = []
        for page in pages {
            for paragraph in paragraphs(fromPage: page) {
                result.append(Paragraph(id: result.count,
                                        pageIndex: page.index,
                                        text: paragraph.text))
            }
        }
        return result
    }

    /// 句边界切分：贪心按句切，单句超限硬切。
    static func splitLong(_ text: String, limit: Int = maxParagraphLength) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? [] : [trimmed] }
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var out: [String] = []
        var piece = ""
        for character in trimmed {
            piece.append(character)
            if terminators.contains(character), piece.count >= limit * 2 / 3 {
                out.append(piece.trimmingCharacters(in: .whitespaces))
                piece = ""
            } else if piece.count >= limit {
                out.append(piece.trimmingCharacters(in: .whitespaces))
                piece = ""
            }
        }
        let rest = piece.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty {
            if let last = out.last, last.count < limit / 3 {
                out[out.count - 1] = last + " " + rest
            } else {
                out.append(rest)
            }
        }
        return out.filter { !$0.isEmpty }
    }

    // MARK: - 搜索

    struct Hit: Identifiable, Equatable, Sendable {
        var pageIndex: Int
        /// 页内第几处命中（0 起）——跳转精确落点用（对齐 v0.8.43 语义）。
        var occurrence: Int
        var snippet: String
        var id: String { "\(pageIndex)-\(occurrence)" }
    }

    /// 大小写不敏感逐页搜索；每页最多 perPage 条，总计最多 limit 条。
    /// 片段复用 EbookSearchCore 的切片逻辑（snippet + snippetSegments）。
    static func search(query: String, pages: [PageText],
                       perPage: Int = 3, limit: Int = 120) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [Hit] = []
        for page in pages {
            let text = page.text
            var cursor = text.startIndex
            var found = 0
            while found < perPage,
                  let range = text.range(of: needle, options: .caseInsensitive,
                                         range: cursor..<text.endIndex) {
                let snippet = EbookSearchCore.snippet(
                    in: text, around: range, radius: 54)
                hits.append(Hit(pageIndex: page.index,
                                occurrence: found, snippet: snippet))
                found += 1
                cursor = range.upperBound
                if cursor >= text.endIndex { break }
            }
            if hits.count >= limit { break }
        }
        return hits
    }
}
