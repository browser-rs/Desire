import Foundation

/// 知识周报的**纯逻辑**（v0.8.22）：挑本周条目、渲染 Markdown。
/// 嵌入与写盘在 `KnowledgeWeeklyDigest`（app 侧）；这里只做可测的部分。
nonisolated enum KnowledgeDigestCore {
    struct Item: Equatable, Sendable {
        var id: String
        var title: String
        var text: String
        /// 来源类型标签（Web / PDF / Reading）。
        var kind: String
        var date: Date
    }

    /// 本周条目：按时间倒序，取最近 `limit` 条。
    static func pickRecent(_ items: [Item], since: Date, limit: Int = 60) -> [Item] {
        items.filter { $0.date >= since }
            .sorted { $0.date > $1.date }
            .prefix(max(1, limit))
            .map { $0 }
    }

    /// 渲染 Markdown：主题簇按传入顺序（已按大小降序），没进任何簇的归"其他"。
    static func markdown(items: [Item], clusters: [[String]],
                         since: Date, until: Date) -> String {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        lines.append("# 知识周报 / Knowledge Weekly")
        lines.append("")
        lines.append("\(formatter.string(from: since)) → \(formatter.string(from: until)) · \(items.count) 条")
        lines.append("")

        var clustered = Set<String>()
        var theme = 0
        for cluster in clusters {
            let members = cluster.compactMap { byID[$0] }
            guard !members.isEmpty else { continue }
            clustered.formUnion(members.map(\.id))
            theme += 1
            lines.append("## 主题 \(theme)（\(members.count) 条）")
            for member in members {
                let snippet = SemanticText.snippet(member.text, max: 140)
                lines.append("- [\(member.kind)] \(member.title) — \(snippet)")
            }
            lines.append("")
        }

        let leftovers = items.filter { !clustered.contains($0.id) }
        if !leftovers.isEmpty {
            lines.append("## 其他（\(leftovers.count) 条）")
            for item in leftovers {
                lines.append("- [\(item.kind)] \(item.title) — \(SemanticText.snippet(item.text, max: 140))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
