import Foundation

/// 研究助手的一个候选来源（v0.8.1）。由当前页、打开的标签、历史正文索引、
/// 浏览历史、阅读列表与书签汇总而来；排序/去重是纯逻辑（`ResearchRanking`）。
nonisolated struct ResearchSource: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case currentPage
        case openTab
        case pageText
        case history
        case readingList
        case bookmark

        /// 同一 URL 出现多种来源时保留更“近”的那一种（当前页 > 打开的标签 >
        /// 正文索引 > 历史 > 阅读列表 > 书签）。
        var priority: Int {
            switch self {
            case .currentPage: 0
            case .openTab: 1
            case .pageText: 2
            case .history: 3
            case .readingList: 4
            case .bookmark: 5
            }
        }

        var label: String {
            switch self {
            case .currentPage: "current page"
            case .openTab: "open tab"
            case .pageText: "indexed page text"
            case .history: "history"
            case .readingList: "reading list"
            case .bookmark: "bookmark"
            }
        }
    }

    var url: String
    var title: String
    /// 可检索正文（当前页取 6000 字；正文索引 3000 字；其余通常为空）。
    var text: String
    var kind: Kind
    var lastVisited: Date?

    var id: String { url }
    var host: String { URL(string: url)?.host?.lowercased() ?? "" }
    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title
    }
}
