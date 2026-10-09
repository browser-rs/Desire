import Foundation

/// 记忆知识库的 Markdown 渲染（ReMe 式思想：记忆成为"可读、可检索、互相
/// 链接"的文档）。纯函数：画像 + 事实 + 会话摘要 → 一份分组 Markdown，
/// 事实之间按共享词元（≥2 个，复用检索分词口径）自动建立"相关"链接。
/// Foundation-only：进 tests/run.sh。桥 `GET /memory/export?format=markdown`。
nonisolated enum MemoryKB {
    struct FactInput {
        let content: String
        let category: String
        let scope: String
        let source: String?
        let pinned: Bool
        let updatedText: String
    }

    struct SummaryInput {
        let title: String
        let text: String
        let updatedText: String
    }

    /// 事实间的"相关"链接：共享 ≥2 个分词词元即视为相关（同一事实自己除外）。
    static func links(for facts: [FactInput]) -> [Int: [Int]] {
        let tokenLists = facts.map { MemoryRetrieval.tokenize($0.content) }
        var out: [Int: [Int]] = [:]
        for i in facts.indices {
            var related: [Int] = []
            for j in facts.indices where j != i {
                let shared = Set(tokenLists[i]).intersection(tokenLists[j])
                if shared.count >= 2 { related.append(j) }
            }
            if !related.isEmpty { out[i] = related }
        }
        return out
    }

    static func render(profile: [String: String],
                       facts: [FactInput],
                       summaries: [SummaryInput],
                       generatedText: String) -> String {
        var out = "# Desire 记忆知识库\n\n> 生成于 \(generatedText)。本文件由本机记忆自动渲染——画像、事实与会话摘要；可直接阅读、检索，或作为迁移备份。\n\n"

        out += "## 画像\n\n"
        for (key, value) in profile where !value.isEmpty {
            out += "- **\(key)**：\(value)\n"
        }
        if profile.values.allSatisfy(\.isEmpty) {
            out += "-（空）\n"
        }

        out += "\n## 事实\n\n"
        if facts.isEmpty {
            out += "-（暂无事实）\n"
        } else {
            let links = links(for: facts)
            let categories = ["fact", "preference", "habit", "correction"]
            var remaining = Set(facts.indices)
            for category in categories {
                let idx = facts.indices.filter { facts[$0].category == category && remaining.contains($0) }
                guard !idx.isEmpty else { continue }
                let title = ["fact": "事实", "preference": "偏好",
                             "habit": "习惯", "correction": "纠正"][category] ?? category
                out += "### \(title)\n\n"
                for i in idx {
                    remaining.remove(i)
                    let f = facts[i]
                    let star = f.pinned ? "★ " : ""
                    let meta = [f.scope == "global" ? nil : "范围 \(f.scope)",
                                f.source].compactMap { $0 }
                    out += "- \(star)\(f.content)（\(meta.joined(separator: " · "))）\n"
                    if let related = links[i], !related.isEmpty {
                        let names = related.map { "「\(prefix(facts[$0].content))」" }
                        out += "  - 相关：\(names.joined(separator: "、"))\n"
                    }
                }
                out += "\n"
            }
            // 其余未归类类别
            for i in remaining.sorted() {
                let f = facts[i]
                out += "- \(f.content)（\(f.category)）\n"
            }
            if remaining.count > 0 { out += "\n" }
        }

        out += "## 会话摘要\n\n"
        if summaries.isEmpty {
            out += "-（暂无摘要）\n"
        } else {
            for summary in summaries {
                out += "### \(summary.title)（\(summary.updatedText)）\n\n\(summary.text)\n\n"
            }
        }
        return out
    }

    private static func prefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 18 ? String(trimmed.prefix(18)) + "…" : trimmed
    }
}
