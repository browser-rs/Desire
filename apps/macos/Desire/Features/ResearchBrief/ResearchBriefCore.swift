import Foundation

/// 研究简报的纯逻辑核心（v0.8.50 批 1）：模型输出解析 + **引用契约** +
/// 逐句核验 + 最终 Markdown 渲染。Foundation-only、进 tests/run.sh。
///
/// 契约（三条硬约束）：
/// 1. 正文只允许引用 `[n]`，n ∈ 1...sources.count；越界引用一律丢弃并计数。
/// 2. 引文（points 里的 quote）必须与源正文**归一化后精确匹配**——不匹配标
///    `verified = false`，最终简报里给出未核验数量（伪造引用不许静默通过）。
/// 3. 列表项（`- `/`* `/`1. `）没有引用 → 追加"未找到来源"标记并计数。
nonisolated enum ResearchBriefCore {

    // MARK: - 模型输出解析

    /// 容错解析 JSON 对象：允许 ```json 围栏、前后废话；取第一个 `{` 到最后一个 `}`。
    static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let slice = raw[start...end]
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// 选题拆解：`{"queries": ["...", ...]}` → 最多 5 条、去重、去空。
    static func parseQueries(_ raw: String, limit: Int = 5) -> [String] {
        guard let object = jsonObject(raw),
              let queries = object["queries"] as? [String] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count >= limit { break }
        }
        return result
    }

    /// 阅读笔记：`{"points": [{"point": "...", "quote": "..."}]}`。
    /// 每条 quote 立即对源正文做逐句核验。
    static func parsePoints(_ raw: String, sourceID: Int, sourceText: String,
                            limit: Int = 5) -> [ResearchBriefPoint] {
        guard let object = jsonObject(raw),
              let items = object["points"] as? [[String: Any]] else { return [] }
        var points: [ResearchBriefPoint] = []
        for item in items {
            let point = (item["point"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = (item["quote"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !point.isEmpty else { continue }
            points.append(ResearchBriefPoint(
                sourceID: sourceID,
                point: point,
                quote: quote,
                verified: verifyQuote(quote, in: sourceText)))
            if points.count >= limit { break }
        }
        return points
    }

    /// 成文：按 `## 标题` 分节。无分节标记时整段作为一个"正文"节。
    static func parseSections(_ raw: String) -> [ResearchBriefSection] {
        var sections: [ResearchBriefSection] = []
        var currentHeading = ""
        var buffer: [String] = []
        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentHeading.isEmpty || !body.isEmpty {
                sections.append(ResearchBriefSection(heading: currentHeading, markdown: body))
            }
            buffer = []
        }
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                currentHeading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("# ") {
                // 一级标题由宿主生成，模型给的一级标题并进正文（不吞内容）。
                buffer.append(line)
            } else {
                buffer.append(line)
            }
        }
        flush()
        // 模型把"来源"也写进正文：宿主重建来源列表，丢掉模型那份。
        return sections.filter { section in
            let heading = section.heading.lowercased()
            return !(heading.contains("来源") || heading.contains("sources") || heading.contains("references"))
        }
    }

    // MARK: - 引用契约

    /// 丢弃越界的 `[n]`（n > sourceCount 或 n < 1），返回清洗后文本与统计。
    static func sanitizeReferences(_ markdown: String, sourceCount: Int) -> (text: String, dropped: Int) {
        var dropped = 0
        var output = ""
        var index = markdown.startIndex
        while index < markdown.endIndex {
            if markdown[index] == "[",
               let close = markdown[index...].firstIndex(of: "]") {
                let inner = markdown[markdown.index(after: index)..<close]
                if let number = Int(inner) {
                    if number >= 1 && number <= sourceCount {
                        output += "[\(number)]"
                    } else {
                        dropped += 1
                    }
                    index = markdown.index(after: close)
                    continue
                }
                // 不是数字引用：原样保留（[链接文本] 等）。
            }
            output.append(markdown[index])
            index = markdown.index(after: index)
        }
        return (output, dropped)
    }

    /// 统计被引用的来源编号集合。
    static func citedSourceIDs(in markdown: String) -> Set<Int> {
        var ids = Set<Int>()
        var index = markdown.startIndex
        while index < markdown.endIndex {
            if markdown[index] == "[",
               let close = markdown[index...].firstIndex(of: "]"),
               let number = Int(markdown[markdown.index(after: index)..<close]) {
                ids.insert(number)
                index = markdown.index(after: close)
                continue
            }
            index = markdown.index(after: index)
        }
        return ids
    }

    /// 列表项没有引用 → 追加"（未找到来源）"标记。返回新文本与被标数。
    static func flagUncitedBullets(_ markdown: String, marker: String) -> (text: String, flagged: Int) {
        var flagged = 0
        let lines = markdown.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
                || trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            guard isBullet else { return line }
            guard citedSourceIDs(in: trimmed).isEmpty else { return line }
            flagged += 1
            return line + " " + marker
        }
        return (lines.joined(separator: "\n"), flagged)
    }

    // MARK: - 引文核验

    /// 归一化：小写、所有空白折叠成单空格、去掉首尾空白。
    /// 保留标点（"逐字"的可读底线：允许排版空白差异，不允许改字）。
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func verifyQuote(_ quote: String, in sourceText: String) -> Bool {
        let normalizedQuote = normalize(quote)
        guard normalizedQuote.count >= 8 else { return false }
        return normalize(sourceText).contains(normalizedQuote)
    }

    // MARK: - 渲染

    /// 最终 Markdown：标题 + 元信息 + 分节 + 宿主重建的来源列表 + 说明。
    static func render(_ document: ResearchBriefDocument) -> String {
        let zh = document.isChinese
        var lines: [String] = []
        lines.append("# \(document.topic)")
        lines.append("")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        let sourceCount = document.sources.filter { !$0.gated && $0.note == nil }.count
        let meta = zh
            ? "生成于 \(formatter.string(from: document.createdAt)) · 来源 \(sourceCount) 篇 · 模板 \(document.template.rawValue) · 未核验引用 \(document.unverifiedQuotes) 处"
            : "Generated \(formatter.string(from: document.createdAt)) · \(sourceCount) source(s) · template \(document.template.rawValue) · \(document.unverifiedQuotes) unverified quote(s)"
        lines.append("> \(meta)")
        lines.append("")

        for section in document.sections {
            if !section.heading.isEmpty {
                lines.append("## \(section.heading)")
                lines.append("")
            }
            if !section.markdown.isEmpty {
                lines.append(section.markdown)
                lines.append("")
            }
        }

        lines.append(zh ? "## 来源" : "## Sources")
        lines.append("")
        for source in document.sources.sorted(by: { $0.id < $1.id }) {
            var entry = "\(source.id). [\(source.title.isEmpty ? source.url : source.title)](\(source.url)) — \(source.domain)"
            if let publishedAt = source.publishedAt, !publishedAt.isEmpty {
                entry += " · \(publishedAt)"
            }
            if source.gated {
                entry += zh ? " ·（登录/付费墙，未取正文）" : " · (gated)"
            } else if let note = source.note {
                entry += zh ? " ·（抓取失败：\(note)）" : " · (failed: \(note))"
            }
            lines.append(entry)
        }
        lines.append("")

        var notes: [String] = []
        if document.unverifiedQuotes > 0 {
            notes.append(zh
                ? "- \(document.unverifiedQuotes) 处引文未能在源正文中逐字匹配（已标 ⚠️，请自行复核）"
                : "- \(document.unverifiedQuotes) quote(s) did not match the source text verbatim (flagged ⚠️)")
        }
        if document.droppedRefs > 0 {
            notes.append(zh
                ? "- 丢弃了 \(document.droppedRefs) 处越界引用（编号超出来源列表）"
                : "- Dropped \(document.droppedRefs) out-of-range citation(s)")
        }
        if document.uncitedBullets > 0 {
            notes.append(zh
                ? "- \(document.uncitedBullets) 条结论未找到来源（已标注）"
                : "- \(document.uncitedBullets) statement(s) had no source (marked)")
        }
        if document.truncatedByBudget {
            notes.append(zh
                ? "- 因预算（页数/字数/token）截断，来源与篇幅可能不完整"
                : "- Truncated by budget (pages/bytes/tokens); coverage may be incomplete")
        }
        if let error = document.error, !error.isEmpty {
            notes.append("- \(error)")
        }
        if !notes.isEmpty {
            lines.append(zh ? "## 说明" : "## Notes")
            lines.append("")
            lines.append(contentsOf: notes)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
