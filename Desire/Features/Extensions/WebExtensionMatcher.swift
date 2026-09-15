import Foundation

/// WebExtension match-pattern evaluation (`*://*.example.com/*`, `<all_urls>`).
enum WebExtensionMatcher {
    static func matches(_ patterns: [String], url: URL) -> Bool {
        patterns.contains { matches($0, url: url) }
    }

    static func matches(_ pattern: String, url: URL) -> Bool {
        guard let regex = patternToRegex(pattern) else { return false }
        return url.absoluteString.range(of: regex, options: .regularExpression) != nil
    }

    /// `*://*.example.com/path*` → anchored regex. `*` scheme = http(s);
    /// `*.host` = host plus any subdomain; `*` in path = any characters.
    static func patternToRegex(_ pattern: String) -> String? {
        guard pattern != "<all_urls>" else { return ".*" }
        let parts = pattern.split(separator: "://", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let scheme = String(parts[0])
        let rest = String(parts[1])

        let hostPath = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(hostPath[0])
        let path = hostPath.count == 2 ? "/" + String(hostPath[1]) : "/"

        let schemeRegex: String
        switch scheme {
        case "*": schemeRegex = "https?"
        default: schemeRegex = NSRegularExpression.escapedPattern(for: scheme)
        }

        let hostRegex: String
        if host == "*" {
            hostRegex = "[^/]*"
        } else if host.hasPrefix("*.") {
            hostRegex = "([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: String(host.dropFirst(2)))
        } else {
            hostRegex = NSRegularExpression.escapedPattern(for: host)
        }

        var pathRegex = ""
        for ch in path {
            pathRegex += ch == "*" ? ".*" : NSRegularExpression.escapedPattern(for: String(ch))
        }
        return "^\(schemeRegex)://\(hostRegex)\(pathRegex)$"
    }
}
