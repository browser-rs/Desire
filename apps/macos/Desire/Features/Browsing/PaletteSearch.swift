import Foundation

/// 命令面板混合检索的**纯逻辑**（v0.7.21 旗舰；Foundation-only，进单测
/// harness）。五源统一为 `Row`（命令 / 打开中的标签 / 书签 / 历史 / Agent
/// 会话），负责**评分、分源分组、截断、显示序列**——UI 只做渲染与键盘。
///
/// 排序规则（与地址栏建议同族的"前缀 > 词首 > 子串"三档 + 模糊兜底）：
///   100 标题前缀 → 80 标题词首（按词边界切）→ 60 标题子串 → 50 URL 子串
///   → 40 副标题子串 → 20 标题模糊子序列。
/// 同分保持**输入顺序**（调用方按"最近使用/最近访问"排好——输入序即时间
/// 序，稳定排序用下标显式兜底）。空查询 = 初始态：命令按调用方给的最近
/// 使用序、标签按窗口顺序。
nonisolated enum PaletteSearch {

    enum Source: String, CaseIterable, Sendable {
        case command, tab, bookmark, history, conversation
    }

    struct Row: Sendable, Equatable {
        let source: Source
        /// 稳定标识：命令 = "cmd.xxx"；标签/会话 = 实体 UUID 字符串；
        /// 书签/历史 = URL（源内天然唯一）。
        let id: String
        let title: String
        /// 第二行展示：命令分类 / URL / 会话摘要。
        let subtitle: String
        /// 可打开的行（⌘Enter 新标签）；命令与标签不需要。
        let url: String?

        init(source: Source, id: String, title: String, subtitle: String, url: String? = nil) {
            self.source = source
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.url = url
        }
    }

    struct Section: Equatable {
        let source: Source
        /// 截断后的行（≤ limit）。
        let rows: [Row]
        /// 该源**命中总数**（徽标显示"显示 8 / 共 23"用）。
        let total: Int
    }

    /// 渲染/键盘导航共用的显示序列：分组头 + 行。
    enum DisplayItem: Equatable {
        case header(source: Source, total: Int)
        case row(Row)

        var rowValue: Row? {
            if case .row(let row) = self { return row }
            return nil
        }
    }

    static let perSourceLimit = 8
    static let initialTabLimit = 8

    // MARK: - 评分

    /// 0 = 不命中。数值越大越靠前。
    static func score(_ row: Row, query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }
        let title = row.title.lowercased()
        let subtitle = row.subtitle.lowercased()
        let url = (row.url ?? "").lowercased()

        if title.hasPrefix(q) { return 100 }
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if title.contains(q) { return 60 }
        if url.contains(q) { return 50 }
        if subtitle.contains(q) { return 40 }
        if fuzzy(title, query: q) { return 20 }
        return 0
    }

    /// 子序列模糊匹配（查询字符按序出现；大小写不敏感——传入已 lowercased）。
    static func fuzzy(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var index = text.startIndex
        for character in query {
            guard let found = text[index...].firstIndex(of: character) else { return false }
            index = text.index(after: found)
        }
        return true
    }

    // MARK: - 检索

    /// 非空查询：按源分组、组内按分排序（同分保持输入序）、截断到 limit。
    static func search(_ query: String, rows: [Row], perSourceLimit: Int = perSourceLimit) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var sections: [Section] = []
        for source in Source.allCases {
            var scored: [(score: Int, order: Int, row: Row)] = []
            for (order, row) in rows.enumerated() where row.source == source {
                let value = score(row, query: q)
                if value > 0 {
                    scored.append((value, order, row))
                }
            }
            guard !scored.isEmpty else { continue }
            scored.sort { a, b in
                a.score != b.score ? a.score > b.score : a.order < b.order
            }
            sections.append(Section(source: source,
                                    rows: scored.prefix(perSourceLimit).map(\.row),
                                    total: scored.count))
        }
        return sections
    }

    /// 空查询初始态：命令（调用方已按最近使用排序）+ 标签（窗口顺序）。
    static func initialSections(rows: [Row],
                                perSourceLimit: Int = perSourceLimit,
                                tabLimit: Int = initialTabLimit) -> [Section] {
        var sections: [Section] = []
        for source in Source.allCases {
            let all = rows.filter { $0.source == source }
            guard !all.isEmpty else { continue }
            let limit = source == .command ? perSourceLimit : (source == .tab ? tabLimit : 0)
            guard limit > 0 else { continue }
            sections.append(Section(source: source,
                                    rows: Array(all.prefix(limit)),
                                    total: all.count))
        }
        return sections
    }

    /// 分组 → 扁平显示序列（组头 + 行；键盘导航只踩行）。
    static func displayItems(_ sections: [Section]) -> [DisplayItem] {
        var items: [DisplayItem] = []
        for section in sections {
            guard !section.rows.isEmpty else { continue }
            items.append(.header(source: section.source, total: section.total))
            items.append(contentsOf: section.rows.map { .row($0) })
        }
        return items
    }
}
