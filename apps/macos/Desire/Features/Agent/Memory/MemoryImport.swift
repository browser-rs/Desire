import Foundation

/// 记忆导入（v0.8.20 Agent 基础 8，对偶 0.7.7 知识库导出）：解析
/// `markdownKB()` 产出的 Markdown——二级标题分节、事实条目为
/// `- [类别][scope] 内容 (来源: …) ⭐` 形态（无匹配的行按 fact 类别收）。
/// 冲突不在解析层处理——调用方把返回内容逐条走 addFact，靠既有
/// areNearDuplicates 去重与冲突复核向导。Foundation-only，进 tests/run.sh。
nonisolated enum MemoryImport {

    struct ParsedFact: Equatable {
        var content: String
        var category: String
        var scope: String
        var source: String?
        var pinned: Bool
    }

    /// 从知识库 Markdown 提取事实条目。真实形态（MemoryKB.render）：
    /// `### 事实/偏好/习惯/纠正` 分节，行 = `- ★内容（范围 host · 来源）`；
    /// 括号元信息可整段缺省。画像/摘要节跳过。
    nonisolated static func parse(_ markdown: String) -> [ParsedFact] {
        let sectionCategories = ["事实": "fact", "偏好": "preference",
                                 "习惯": "habit", "纠正": "correction"]
        var out: [ParsedFact] = []
        var currentCategory = "fact"
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                let title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                currentCategory = sectionCategories[title] ?? ""
                continue
            }
            // 离开事实节（进入摘要/画像等新二级标题）。
            if line.hasPrefix("## ") { currentCategory = ""; continue }
            guard !currentCategory.isEmpty, line.hasPrefix("- ") else { continue }
            var body = String(line.dropFirst(2))
            // 生成端是 "★ "（带空格）；容忍 "★" 紧贴的旧文件/手写形态。
            let pinned = body.hasPrefix("★ ") || body.hasPrefix("★")
            if pinned, body.hasPrefix("★") {
                body = String(body.dropFirst(body.hasPrefix("★ ") ? 2 : 1))
                    .trimmingCharacters(in: .whitespaces)
            }
            // 尾部括号元信息："（范围 host · 来源标题）"——来源可单独出现。
            var scope = "global"
            var source: String?
            if body.hasSuffix("）"), let open = body.lastIndex(of: "（") {
                let meta = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
                body = String(body[..<open]).trimmingCharacters(in: .whitespaces)
                for part in meta.components(separatedBy: " · ") {
                    let piece = part.trimmingCharacters(in: .whitespaces)
                    if piece.hasPrefix("范围 ") {
                        scope = String(piece.dropFirst("范围 ".count))
                    } else if !piece.isEmpty {
                        source = piece
                    }
                }
            }
            let content = body.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, !content.hasPrefix("（暂无"), content.count <= 2_000 else { continue }
            out.append(ParsedFact(content: content, category: currentCategory,
                                  scope: scope, source: source, pinned: pinned))
        }
        return out
    }
}
