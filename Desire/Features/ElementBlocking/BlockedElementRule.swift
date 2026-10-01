import Foundation

struct BlockedElementRule: Identifiable, Codable {
    let id: UUID
    var urlPattern: String
    var cssSelector: String
    var xpath: String?
    var createdAt: Date

    init(id: UUID = UUID(), urlPattern: String, cssSelector: String, xpath: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.urlPattern = urlPattern
        self.cssSelector = cssSelector
        self.xpath = xpath
        self.createdAt = createdAt
    }

    func matches(host: String) -> Bool {
        if urlPattern == "*" { return true }
        if urlPattern == host { return true }
        if urlPattern.hasPrefix("*.") {
            let domain = String(urlPattern.dropFirst(2))
            return host == domain || host.hasSuffix("." + domain)
        }
        // 旧实现 host.contains(urlPattern) 过宽——"example.com" 会命中
        // "notexample.com"。改为后缀点分语义（子域命中，碰巧含子串不命中）。
        return host == urlPattern || host.hasSuffix("." + urlPattern)
    }
}
