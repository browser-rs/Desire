import Foundation

/// 搜索结果解析（v0.8.50 批 2）。Foundation-only、进 tests/run.sh。
///
/// 不绑定单一引擎：对 Bing / DuckDuckGo(html) / 百度 的结果页做**通用锚点抽取**
/// （`<a href=...>标题</a>`），再按噪声规则过滤：
/// - 只留 http(s)；相对地址按 base 解析；
/// - DDG 的 `//duckduckgo.com/l/?uddg=<encoded>` 还原真实地址；
/// - 丢掉登录/搜索/导航类链接与图片、脚本、样式资源；
/// - 同域最多 2 条（域名多样性交给上层再排一次）；标题过短或纯"更多/登录"丢掉。
///
/// 取证：`tests/fixtures/search/*.html` 三段真实结构快照断言命中集合。
nonisolated enum ResearchBriefSearchParser {

    struct Hit: Equatable {
        var title: String
        var url: String
        var domain: String
    }

    private static let junkHosts: Set<String> = [
        "www.bing.com", "bing.com", "cn.bing.com",
        "duckduckgo.com", "html.duckduckgo.com", "www.baidu.com", "baidu.com",
    ]

    private static let junkURLParts: [String] = [
        "/search?", "/login", "/signin", "/signup", "/register", "/help",
        "/preferences", "/settings", "/account", "/privacy", "/terms",
        "javascript:", "mailto:", "#",
    ]

    private static let junkExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "svg", "ico",
        "css", "js", "pdf", "zip", "mp4", "mp3",
    ]

    private static let junkTitles: Set<String> = [
        "更多", "登录", "注册", "首页", "下一页", "上一页", "more", "next", "previous",
        "sign in", "log in", "settings", "images", "videos", "news", "maps",
    ]

    static func parse(html: String, baseURL: String, limit: Int = 12) -> [Hit] {
        let pattern = #"<a\s[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var hits: [Hit] = []
        var seen = Set<String>()
        var perDomain: [String: Int] = [:]

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let rawHref = ns.substring(with: match.range(at: 1))
            let rawTitle = ns.substring(with: match.range(at: 2))
            guard let url = realURL(from: rawHref, baseURL: baseURL),
                  let host = URL(string: url)?.host?.lowercased() else { continue }
            // 百度/必应的结果可能是**跳转链接**（www.baidu.com/link?url=…）：
            // 跳转链接本身不算"自家站内导航"，放行（抓取时跟随到真实地址）。
            let isRedirect = url.lowercased().contains("/link?url=")
            guard !(junkHosts.contains(host) && !isRedirect) else { continue }
            let title = cleanTitle(rawTitle)
            guard title.count >= 6, !junkTitles.contains(title.lowercased()) else { continue }
            let key = url.lowercased()
            guard seen.insert(key).inserted else { continue }
            let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let count = perDomain[domain, default: 0]
            guard count < 2 else { continue }
            perDomain[domain] = count + 1
            hits.append(Hit(title: title, url: url, domain: domain))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// 结果链接规范化：DDG 跳转还原、相对地址补全、过滤资源与导航链接。
    static func realURL(from raw: String, baseURL: String) -> String? {
        var value = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        if let range = value.range(of: "uddg=") {
            let encoded = String(value[range.upperBound...])
                .components(separatedBy: "&").first ?? ""
            if let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("http") {
                value = decoded
            }
        }
        if value.hasPrefix("/") {
            guard let base = URL(string: baseURL),
                  let absolute = URL(string: value, relativeTo: base)?.absoluteString else { return nil }
            value = absolute
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return nil }
        let lower = value.lowercased()
        for part in junkURLParts where lower.contains(part) { return nil }
        let ext = (lower as NSString).pathExtension
        if junkExtensions.contains(ext) { return nil }
        return value
    }

    static func cleanTitle(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: "",
                                                options: .regularExpression)
        return decodeEntities(stripped)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
