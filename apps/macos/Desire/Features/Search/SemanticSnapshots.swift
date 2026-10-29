import Foundation

/// 各数据源 → 语义索引条目的**纯映射**（v0.8.22，Foundation-only，进 harness）。
///
/// 只做"能索引什么"的判定与正文组装，不读盘、不碰 store——store 侧取快照
/// 后交给这里，测试与桥探针可以喂构造数据。会话（Conversation）依赖
/// AgentMessage 的完整模型，映射放在 app 侧的 SemanticIndexSources。
nonisolated enum SemanticSnapshots {
    static let historyLimit = 800
    static let excerptLimit = 500
    static let highlightLimit = 500
    static let bookmarkLimit = 5_000

    /// 历史正文（opt-in 的历史正文索引记录；未开启时集合为空）。
    static func history(_ records: [HistoryContentRecord]) -> [SemanticItem] {
        records.prefix(historyLimit).map { record in
            SemanticItem(
                source: .history,
                externalID: record.url,
                title: record.title,
                subtitle: record.url,
                body: record.text,
                updatedAt: record.updatedAt)
        }
    }

    /// 书签只收**叶子**（文件夹没有内容）；正文 = 标题 + 标签 + URL 路径。
    /// 标签是用户自己写的分类词，对语义召回很有用。
    ///
    /// **语义信息量门槛**：纯导航名（"GitHub"/"Stack Overflow"）的向量过于
    /// 通用——实测无关英文查询对这类短标题能到 0.48，比真正的同义改写命中
    /// （0.52）只低一点点，阈值分不开。这类条目没有检索价值（用户会用字面
    /// 搜索找它们），直接不入索引。判定：有标签 → 收；中文 ≥ 6 字 → 收；
    /// 英文 ≥ 4 个有效词 → 收。
    static func bookmarks(_ roots: [Bookmark]) -> [SemanticItem] {
        var items: [SemanticItem] = []
        func walk(_ nodes: [Bookmark]) {
            for node in nodes {
                guard items.count < bookmarkLimit else { return }
                if let url = node.url {
                    let tags = (node.tags ?? []).joined(separator: " ")
                    // 正文只留**路径 slug**（"offline-reading-notes" 这种有语义），
                    // 去掉 scheme/host——"https://github.com" 这类纯域名会把
                    // 短标题的向量拉得过分通用（实测无关查询能到 0.42）。
                    var parts = [node.title, tags]
                    if let path = URL(string: url)?.path, path != "/", !path.isEmpty {
                        parts.append(path
                            .replacingOccurrences(of: "/", with: " ")
                            .replacingOccurrences(of: "-", with: " ")
                            .replacingOccurrences(of: "_", with: " "))
                    }
                    let body = parts
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .joined(separator: "\n")
                    guard isSemanticallyRich(title: node.title, tags: tags, path: parts.count > 2 ? parts[2] : "") else {
                        continue
                    }
                    items.append(SemanticItem(
                        source: .bookmark,
                        externalID: node.id.uuidString,
                        title: node.title,
                        subtitle: url,
                        body: body,
                        updatedAt: node.updatedAt ?? .distantPast))
                } else {
                    walk(node.children)
                }
            }
        }
        walk(roots)
        return items
    }

    /// 书签是否带足够语义（见 `bookmarks` 的说明）。
    static func isSemanticallyRich(title: String, tags: String, path: String) -> Bool {
        if !tags.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let payload = title + " " + path
        if SemanticText.detectLanguage(payload) == .chinese {
            return SemanticText.cjkCount(payload) >= 6
        }
        let words = payload
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "/" })
            .filter { $0.count >= 2 }
        return words.count >= 4
    }

    /// 摘录：正文 + 备注（备注是用户的二次加工，必须进索引）。
    static func excerpts(_ excerpts: [Excerpt]) -> [SemanticItem] {
        excerpts.prefix(excerptLimit).map { excerpt in
            var body = excerpt.content
            if let note = excerpt.note, !note.isEmpty {
                body += "\n" + note
            }
            return SemanticItem(
                source: .excerpt,
                externalID: excerpt.id.uuidString,
                title: excerpt.title,
                subtitle: excerpt.source,
                body: body,
                updatedAt: excerpt.updatedAt)
        }
    }

    /// 阅读高亮：引文 + 备注。
    static func highlights(_ highlights: [ReaderHighlight]) -> [SemanticItem] {
        highlights.prefix(highlightLimit).map { highlight in
            var body = highlight.quote
            if let note = highlight.note, !note.isEmpty {
                body += "\n" + note
            }
            return SemanticItem(
                source: .highlight,
                externalID: highlight.id.uuidString,
                title: highlight.quote,
                subtitle: highlight.url,
                body: body,
                updatedAt: highlight.createdAt)
        }
    }
}
