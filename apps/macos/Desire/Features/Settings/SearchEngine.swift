import Foundation

struct CustomSearchEngine: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var searchURL: String
    var suggestionURL: String
    /// 地址栏关键字（可选）：`gh rust` → 用此引擎搜 rust。nil = 无关键字。
    /// 搜索 URL 用 %s 或 {searchTerms} 占位（替换为去掉关键字后的查询词）。
    var keyword: String?
}

enum SearchEngine: String, CaseIterable, Codable {
    case google = "Google"
    case duckduckgo = "DuckDuckGo"
    case bing = "Bing"
    case baidu = "Baidu"

    var searchURL: String {
        switch self {
        case .google: "https://www.google.com/search?q="
        case .duckduckgo: "https://duckduckgo.com/?q="
        case .bing: "https://www.bing.com/search?q="
        case .baidu: "https://www.baidu.com/s?wd="
        }
    }

    var suggestionURL: String {
        switch self {
        case .google: "https://suggestqueries.google.com/complete/search?client=firefox&q="
        case .duckduckgo: "https://ac.duckduckgo.com/ac/?type=list&q="
        case .bing: "https://www.bing.com/osjson.aspx?query="
        case .baidu: "https://suggestion.baidu.com/su?action=opensearch&wd="
        }
    }
}
