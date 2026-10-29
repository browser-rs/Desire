import Foundation

struct AddressSuggestion: Identifiable {
    enum Kind: String {
        case navigate
        case searchDefault
        case searchSuggestion
        case bookmark
        case history
        case openTab
        case calculator
        /// 语义兜底（v0.8.22）：字面无候选时列出的相关页面/摘录。
        case related
    }

    let kind: Kind
    let title: String
    let url: String
    let domain: String?
    /// 非nil = 切换到已打开标签（openTab / calculator 的动作目标不同）。
    var tabID: UUID? = nil

    /// Content-stable identity: the same (kind, url) pair keeps its id
    /// across rebuilds, so SwiftUI's ForEach diffs rows incrementally
    /// instead of treating every keystroke's rebuild as all-new rows.
    var id: String { "\(kind.rawValue)|\(url)|\(tabID?.uuidString ?? "")" }
}
