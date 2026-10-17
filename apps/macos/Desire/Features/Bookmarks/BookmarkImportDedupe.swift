import Foundation

/// 书签导入的**去重纯逻辑**（向导与桥共用）：URL 归一化 + 现有/组内重复
/// 划分 + 树过滤。
///
/// 归一化刻意保守——只折叠"结构上等价"的写法（scheme/host 小写、去
/// fragment、去尾斜杠、省略默认端口）；**不**做模糊匹配：不同路径/查询
/// 一律算不同书签（导入向导宁可少报重复，不能误合并用户的收藏）。
/// http 与 https 视为不同。
enum BookmarkImportDedupe {

    enum DuplicateKind: String {
        /// 与现有书签库里的某条同 URL。
        case existing
        /// 与本文件内更早的一条同 URL（导入集内部重复）。
        case withinImport

        var isExisting: Bool { self == .existing }
    }

    struct Row: Equatable {
        var title: String
        var url: String
        var kind: DuplicateKind
    }

    struct Plan {
        /// "跳过重复"策略的结果树（保留原节点 id/结构，剔除重复叶子；
        /// 子项全被剔除的文件夹一并去掉）。
        var filtered: [Bookmark]
        /// 原树里的叶子总数。
        var total: Int
        var existingDuplicates: [Row]
        var innerDuplicates: [Row]

        var fresh: Int { total - existingDuplicates.count - innerDuplicates.count }
        var duplicateCount: Int { existingDuplicates.count + innerDuplicates.count }
        var hasDuplicates: Bool { duplicateCount > 0 }
    }

    /// 结构折叠：scheme/host 小写、去 fragment、去尾斜杠、去默认端口。
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed) else {
            return trimmed.lowercased()
        }
        comps.fragment = nil
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        if (comps.scheme == "http" && comps.port == 80) || (comps.scheme == "https" && comps.port == 443) {
            comps.port = nil
        }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        return comps.string ?? trimmed
    }

    /// 划分导入树：现有重复（先查）→ 组内重复（后查）→ 其余保留。
    /// 顺序即语义：同 URL 同时撞现有库与组内时算现有重复。
    static func plan(incoming: [Bookmark], existingURLs: Set<String>) -> Plan {
        let seenExisting = Set(existingURLs.map { normalize($0) })
        var seenWithin = Set<String>()
        var existingRows: [Row] = []
        var withinRows: [Row] = []
        var total = 0

        func filter(_ nodes: [Bookmark]) -> [Bookmark] {
            var kept: [Bookmark] = []
            for node in nodes {
                if let url = node.url {
                    total += 1
                    let key = normalize(url)
                    if seenExisting.contains(key) {
                        existingRows.append(Row(title: node.title, url: url, kind: .existing))
                    } else if seenWithin.contains(key) {
                        withinRows.append(Row(title: node.title, url: url, kind: .withinImport))
                    } else {
                        seenWithin.insert(key)
                        kept.append(node)
                    }
                } else {
                    let children = filter(node.children)
                    // 子项被剔除光的**非空**文件夹也去掉（空壳噪音）；
                    // 原本就空的文件夹保留（是用户的组织意图）。
                    if children.isEmpty && !node.children.isEmpty { continue }
                    var copy = node
                    copy.children = children
                    kept.append(copy)
                }
            }
            return kept
        }

        let filtered = filter(incoming)
        return Plan(filtered: filtered, total: total,
                    existingDuplicates: existingRows, innerDuplicates: withinRows)
    }

    /// 树里的叶子总数（桥回执用）。
    static func leafCount(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.url != nil ? 1 : leafCount($1.children)) }
    }
}
