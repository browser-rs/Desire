import Foundation

/// 研究来源的去重、排序与引用格式（纯逻辑，进 tests/run.sh）。
///
/// 检索语义与历史正文索引一致（复用 `HistoryContentSearch`）：查询的每个
/// 英文词/中文字都必须出现在候选的标题+正文+URL 里；标题命中额外加权，
/// 当前页/打开的标签优先于历史。确定性、离线、零模型调用。
nonisolated enum ResearchRanking {
    /// 同 URL 去重：保留优先级更高的来源；正文缺失时从低优先级来源补齐。
    static func merge(_ sources: [ResearchSource]) -> [ResearchSource] {
        var byURL: [String: ResearchSource] = [:]
        var order: [String] = []
        for source in sources {
            let key = normalizeURL(source.url)
            guard !key.isEmpty else { continue }
            guard var existing = byURL[key] else {
                byURL[key] = source
                order.append(key)
                continue
            }
            if source.kind.priority < existing.kind.priority {
                var replacement = source
                if replacement.text.isEmpty { replacement.text = existing.text }
                if replacement.lastVisited == nil { replacement.lastVisited = existing.lastVisited }
                byURL[key] = replacement
            } else if existing.text.isEmpty, !source.text.isEmpty {
                existing.text = source.text
                if existing.lastVisited == nil { existing.lastVisited = source.lastVisited }
                byURL[key] = existing
            }
        }
        return order.compactMap { byURL[$0] }
    }

    /// URL 归一（去空白与 fragment；scheme/host 小写）。查询参数保留——
    /// 不同 `?id=` 通常就是不同内容。
    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed) else { return trimmed }
        components.fragment = nil
        if let scheme = components.scheme { components.scheme = scheme.lowercased() }
        components.host = components.host?.lowercased()
        return components.string ?? trimmed
    }

    /// 排序后的来源（最多 `limit` 条）。空查询 = 按来源优先级与最近访问排序。
    static func rank(query: String,
                     candidates: [ResearchSource],
                     limit: Int = 8) -> [ResearchSource] {
        let merged = merge(candidates)
        let parts = HistoryContentSearch.queryParts(query)
        var scored: [(source: ResearchSource, score: Double)] = []
        for source in merged {
            let all = HistoryContentSearch.indexTokens(
                "\(source.title) \(source.text) \(source.url)")
            if !parts.required.isEmpty,
               !parts.required.allSatisfy({ all.contains($0) }) {
                continue
            }
            let titleTokens = HistoryContentSearch.indexTokens(source.title)
            var score = Double(parts.required.count)
            score += Double(parts.bonus.filter { all.contains($0) }.count) * 2
            score += Double(parts.required.filter { titleTokens.contains($0) }.count) * 3
            switch source.kind {
            case .currentPage: score += 2.5
            case .openTab: score += 1.5
            case .pageText: score += 0.5
            case .history, .readingList, .bookmark: break
            }
            if source.text.isEmpty { score -= 0.25 }
            scored.append((source, score))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let l = $0.source.lastVisited ?? .distantPast
            let r = $1.source.lastVisited ?? .distantPast
            if l != r { return l > r }
            if $0.source.kind.priority != $1.source.kind.priority {
                return $0.source.kind.priority < $1.source.kind.priority
            }
            return $0.source.displayTitle.localizedCaseInsensitiveCompare(
                $1.source.displayTitle) == .orderedAscending
        }
        return Array(scored.prefix(min(20, max(1, limit))).map(\.source))
    }

    /// 给模型的引用块：编号 + 标题 + URL + 来源类型 + 命中片段。
    static func promptBlock(query: String, sources: [ResearchSource]) -> String {
        guard !sources.isEmpty else {
            return "No local sources matched “\(query)”. Do not invent citations; "
                + "try a broader query, open a relevant page, or use readURL."
        }
        var lines = ["Local research sources for “\(query)” (most relevant first):"]
        for (index, source) in sources.enumerated() {
            lines.append("[\(index + 1)] \(source.displayTitle) — \(source.url)")
            var meta = "    \(source.kind.label)"
            if !source.host.isEmpty { meta += " · \(source.host)" }
            lines.append(meta)
            let snippet = HistoryContentSearch.snippet(text: source.text, query: query)
            if !snippet.isEmpty {
                lines.append("    \(snippet)")
            }
        }
        lines.append("")
        lines.append("Cite factual claims with [n]. These sources are local (no network); "
            + "use readURL/openTab when more depth is needed.")
        return lines.joined(separator: "\n")
    }
}
