import Foundation

/// Single source of truth for interpreting address-bar input.
///
/// Both the suggestion preview (`AddressSuggestionsModel`) and the actual
/// navigation (`BrowsingActions.navigateToURL`) must resolve through THIS
/// type. Previously there were three divergent copies of the heuristic and
/// they disagreed: the dropdown promised "Search for 'foo bar.com'" while
/// Enter built the invalid URL `https://foo bar.com` and silently did
/// nothing, and `localhost:8080` / `1.5` were treated as search terms.
enum URLResolution {
    /// What typed text should do.
    enum Destination: Equatable {
        /// Navigate to this absolute URL string.
        case url(String)
        /// Run a web search for `query` on `engine`.
        case search(query: String, engine: SearchTarget)
    }

    /// The engine a search runs on — built-in or custom, resolved to a
    /// display name plus URL template so callers need no Settings access.
    struct SearchTarget: Equatable {
        let displayName: String
        let searchTemplate: String
    }

    /// Resolves typed text to a destination. Always returns an answer for
    /// non-empty input (worst case: a search) — callers must never end up
    /// with a silently-dropped navigation.
    static func resolve(_ rawInput: String, settings: Settings) -> Destination? {
        let text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. Explicit scheme — trust it when it parses. Covers standard
        //    schemes (https://, about:, desire://) AND custom application
        //    schemes (tg://, spotify://, vscode:// …) which the webview
        //    hands to the OS. A scheme plus a space ("https://foo bar")
        //    is junk; search for it instead.
        if text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil {
            if URL(string: text) != nil {
                return .url(text)
            }
            return .search(query: text, engine: defaultTarget(settings))
        }

        // 2. Engine keyword routing: "baidu 关键词", "bing 关键词", or the
        //    lowercased name of any custom engine.
        if let (target, remainder) = keywordTarget(in: text, settings: settings) {
            return .search(query: remainder, engine: target)
        }

        // 3. Scheme-less URL heuristics (localhost, IP literals, host.TLD).
        if looksLikeURL(text) {
            // localhost and IP literals have no certificates to serve —
            // upgrading them guarantees a TLS error page (router admin
            // pages, local dev servers). Everything else upgrades.
            let scheme: String = prefersPlainHTTP(text) ? "http://" : "https://"
            let candidate = scheme + text
            if URL(string: candidate) != nil {
                return .url(candidate)
            }
        }

        // 4. Everything else is a search on the active engine.
        return .search(query: text, engine: defaultTarget(settings))
    }

    /// Builds the final request URL for a search destination.
    static func searchURL(query: String, target: SearchTarget) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: target.searchTemplate + encoded)
    }

    // MARK: - Heuristics

    /// "baidu 关键词" style routing: the FIRST whitespace-separated token
    /// matched against built-in engine ids (case-insensitive) or custom
    /// engine names. The remainder is the query. A bare engine word with no
    /// query ("baidu") is NOT a keyword hit — it stays a normal search.
    private static func keywordTarget(in text: String, settings: Settings) -> (SearchTarget, String)? {
        guard let space = text.firstIndex(where: { $0 == " " }) else { return nil }
        let firstWord = String(text[..<space]).lowercased()
        let remainder = String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        for engine in SearchEngine.allCases where firstWord == engine.rawValue {
            return (SearchTarget(displayName: engine.rawValue, searchTemplate: engine.searchURL), remainder)
        }
        for engine in settings.customEngines where firstWord == engine.name.lowercased() {
            return (SearchTarget(displayName: engine.name, searchTemplate: engine.searchURL), remainder)
        }
        return nil
    }

    /// Scheme-less URL plausibility: no spaces, a host-ish head, and either
    /// `localhost[:port]`, a dotted IPv4 literal, or a host whose last label
    /// is an alphabetic TLD. Rejects numbers like `1.5` / `3.14` (two numeric
    /// labels — a search term, not an address).
    private static func looksLikeURL(_ text: String) -> Bool {
        guard !text.contains(" "), !text.contains("?"), !text.contains("#") else { return false }
        if text == "localhost" || text.hasPrefix("localhost:") || text.hasPrefix("localhost/") {
            return true
        }
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }

        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 }) {
            return true
        }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { label in
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// Hosts that must keep plain http when typed without a scheme:
    /// localhost variants and dotted IPv4 literals (127.0.0.1:8877,
    /// 192.168.1.1 …).
    private static func prefersPlainHTTP(_ text: String) -> Bool {
        if text == "localhost" || text.hasPrefix("localhost:") || text.hasPrefix("localhost/") {
            return true
        }
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let labels = host.split(separator: ".")
        return labels.count == 4 && labels.allSatisfy { $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255 }
    }

    /// The engine currently in effect (custom wins over built-in).
    static func defaultTarget(_ settings: Settings) -> SearchTarget {
        if let id = settings.selectedCustomEngineId,
           let engine = settings.customEngines.first(where: { $0.id == id }) {
            return SearchTarget(displayName: engine.name, searchTemplate: engine.searchURL)
        }
        return SearchTarget(displayName: settings.searchEngine.rawValue,
                            searchTemplate: settings.searchEngine.searchURL)
    }
}
