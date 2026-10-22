import Foundation

/// 提及雷达的来源（v0.8.2）：一个可搜索的入口（搜索引擎/社区搜索/热榜）。
/// URL 模板用 `{query}` 占位；没有占位时自动追加 `?q=`。
nonisolated struct MentionSource: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var platform: String
    var searchURL: String
    var isEnabled: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, platform: String, searchURL: String,
         isEnabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.platform = platform
        self.searchURL = searchURL
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// 常见入口模板（用户可以改用自己常用的搜索/社区）。
    static let presets: [MentionSource] = [
        MentionSource(name: "DuckDuckGo", platform: "Web",
                      searchURL: "https://duckduckgo.com/html/?q={query}"),
        MentionSource(name: "Bing", platform: "Web",
                      searchURL: "https://www.bing.com/search?q={query}"),
        MentionSource(name: "V2EX", platform: "V2EX",
                      searchURL: "https://www.v2ex.com/search?q={query}"),
        MentionSource(name: "Hacker News", platform: "Hacker News",
                      searchURL: "https://hn.algolia.com/?q={query}"),
    ]
}

/// 提及雷达的纯逻辑（Foundation-only，进 harness）：URL 模板展开与命中
/// 去重。抓取在 `MentionRadarScanner`（需要 WebKit），这里只做可测部分。
nonisolated enum MentionRadar {
    struct Hit: Equatable {
        let url: String
        let title: String
        let snippet: String
    }

    static func searchURL(for source: MentionSource, query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        if source.searchURL.contains("{query}") {
            return source.searchURL.replacingOccurrences(of: "{query}", with: encoded)
        }
        guard var components = URLComponents(string: source.searchURL) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "q" || $0.name == "query" }
        items.append(URLQueryItem(name: "q", value: trimmed))
        components.queryItems = items
        return components.url?.absoluteString
    }

    /// 命中 → 去重后的草稿（纯值；由 @MainActor 的扫描器转成互动台账条目，
    /// 避免非隔离上下文构造 MainActor 类型）。
    struct Draft: Equatable {
        let url: String
        let title: String
        let snippet: String
    }

    static func drafts(hits: [Hit], query: String,
                       limit: Int = 20) -> [Draft] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [Draft] = []
        for hit in hits {
            guard out.count < limit else { break }
            let url = hit.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") else {
                continue
            }
            let haystack = (hit.title + " " + hit.snippet).lowercased()
            guard haystack.contains(needle) else { continue }
            guard seen.insert(url).inserted else { continue }
            let snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Draft(url: url,
                             title: String(hit.title.prefix(160)),
                             snippet: String((snippet.isEmpty ? hit.title : snippet).prefix(400))))
        }
        return out
    }
}
