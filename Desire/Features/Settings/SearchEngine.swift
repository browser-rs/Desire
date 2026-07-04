import Foundation

enum SearchEngine: String, CaseIterable {
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
