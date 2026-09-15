import Foundation

/// Converts Adblock Plus filter syntax (EasyList / EasyList China) into
/// Safari content-blocker JSON consumable by `WKContentRuleList`.
///
/// Supported subset — covers the overwhelming majority of real list lines:
/// - `||host^` / `||host/path` with `*` wildcards, plain substrings, `/regex/`
/// - options: `$third-party`, `~third-party`, `domain=a|~b`, resource types
///   (image/script/stylesheet/xmlhttprequest/media/font/object/subdocument/websocket)
/// - `@@…` exceptions → `ignore-previous-rules` (emitted AFTER block rules,
///   which is the order content blockers require for them to take effect)
/// - `##selector` / `domain##selector` element hiding → `css-display-none`
///
/// Unsupported (skipped + counted): `#@#` exception hiding (content blockers
/// have no unhide), `$popup`/`$document`/`$csp`/unknown options.
enum ABPRuleConverter {
    struct Result {
        let json: String
        let ruleCount: Int
        let skippedCount: Int
    }

    /// Safety cap — keeps a hostile/corrupt list from exhausting memory.
    static let maxRules = 60_000

    /// Converts with element-hiding rules included. On a compile failure the
    /// store retries with `includeHiding: false` (one bad CSS selector must
    /// not take the whole list down).
    static func convert(_ abpText: String, includeHiding: Bool = true) -> Result {
        var blocking: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var hiding: [[String: Any]] = []
        var skipped = 0

        for rawLine in abpText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[Adblock") { continue }
            if blocking.count + exceptions.count + hiding.count >= maxRules { skipped += 1; continue }

            // Exception element hiding (#@#) has no content-blocker equivalent.
            if line.contains("#@#") { skipped += 1; continue }

            if includeHiding, let hash = line.range(of: "##") {
                let domainPart = String(line[..<hash.lowerBound])
                let selector = String(line[hash.upperBound...])
                guard isPlausibleSelector(selector) else { skipped += 1; continue }
                var trigger: [String: Any] = ["url-filter": ".*"]
                let domains = domainPart.split(separator: ",").map(String.init)
                if !domains.isEmpty {
                    let include = domains.filter { !$0.hasPrefix("~") }.map { "*" + $0 }
                    let exclude = domains.filter { $0.hasPrefix("~") }.map { "*" + $0.dropFirst() }
                    if !include.isEmpty { trigger["if-domain"] = include }
                    if !exclude.isEmpty { trigger["unless-domain"] = exclude }
                }
                hiding.append(["trigger": trigger,
                               "action": ["type": "css-display-none", "selector": selector]])
                continue
            }

            if let rule = convertNetworkRule(line, isException: line.hasPrefix("@@")) {
                if line.hasPrefix("@@") { exceptions.append(rule) }
                else { blocking.append(rule) }
            } else {
                skipped += 1
            }
        }

        // ignore-previous-rules only neutralizes rules EARLIER in the list,
        // so exceptions must come last.
        let rules = blocking + hiding + exceptions
        let count = rules.count
        let json = (try? JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return Result(json: json, ruleCount: count, skippedCount: skipped)
    }

    // MARK: - Network rules

    private static func convertNetworkRule(_ line: String, isException: Bool) -> [String: Any]? {
        var address = isException ? String(line.dropFirst(2)) : line
        var options: [String] = []

        if isRegexRule(address) {
            // /regex/ — verbatim, no option delimiter parsing.
        } else if let dollar = address.firstIndex(of: "$") {
            options = String(address[address.index(after: dollar)...]).split(separator: ",").map(String.init)
            address = String(address[..<dollar])
            if address.isEmpty { return nil }
        }

        var loadTypes: [String]?
        var resourceTypes: [String]?
        var ifDomains: [String]?
        var unlessDomains: [String]?

        for option in options {
            switch option {
            case "third-party": loadTypes = ["third-party"]
            case "~third-party": loadTypes = ["first-party"]
            case "image": append(&resourceTypes, "image")
            case "script": append(&resourceTypes, "script")
            case "stylesheet": append(&resourceTypes, "style")
            case "xmlhttprequest": append(&resourceTypes, "raw")
            case "media": append(&resourceTypes, "media")
            case "font": append(&resourceTypes, "font")
            case "object", "other": append(&resourceTypes, "other")
            case "subdocument": append(&resourceTypes, "document")
            case "websocket": append(&resourceTypes, "websocket")
            case "important": break // no equivalent — keep the block anyway
            case "popup", "document", "csp", "generichide", "elemhide", "ghide", "ehide", "inline-script":
                return nil // not expressible — drop the rule
            default:
                if option.hasPrefix("domain=") {
                    for d in option.dropFirst("domain=".count).split(separator: "|") {
                        let domain = String(d)
                        if domain.hasPrefix("~") {
                            append(&unlessDomains, "*" + domain.dropFirst())
                        } else {
                            append(&ifDomains, "*" + domain)
                        }
                    }
                } else {
                    return nil // unknown option — be conservative
                }
            }
        }

        var trigger: [String: Any] = ["url-filter": addressRegex(address)]
        if let loadTypes { trigger["load-type"] = loadTypes }
        if let resourceTypes { trigger["resource-type"] = resourceTypes }
        if let ifDomains { trigger["if-domain"] = ifDomains }
        if let unlessDomains { trigger["unless-domain"] = unlessDomains }

        return ["trigger": trigger,
                "action": ["type": isException ? "ignore-previous-rules" : "block"]]
    }

    // MARK: - Address → regex

    private static func addressRegex(_ address: String) -> String {
        if isRegexRule(address) {
            return String(address.dropFirst().dropLast())
        }
        var body = address
        var prefix = ".*"
        var suffix = ".*"
        if body.hasPrefix("||") {
            body = String(body.dropFirst(2))
            prefix = "^https?://([^/]+\\.)?"
        } else if body.hasPrefix("|") {
            body = String(body.dropFirst(1))
            prefix = "^"
        }
        if body.hasSuffix("|") {
            body = String(body.dropLast())
            suffix = "$"
        }
        return prefix + escape(body) + suffix
    }

    /// ABP pattern → regex: `*` wildcard, `^` separator, everything else escaped.
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            switch ch {
            case "*": out += ".*"
            case "^": out += "(?:[/?#]|$)"
            case ".": out += "\\."
            case "+": out += "\\+"
            case "?": out += "\\?"
            case "(", ")": out += "\\" + String(ch)
            case "[", "]": out += "\\" + String(ch)
            case "{", "}": out += "\\" + String(ch)
            case "\\": out += "\\\\"
            case "$": out += "\\$"
            case "|": out += "\\|"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func isRegexRule(_ address: String) -> Bool {
        address.count >= 2 && address.hasPrefix("/") && address.hasSuffix("/")
    }

    private static func append(_ array: inout [String]?, _ value: String) {
        array = (array ?? []) + [value]
    }

    /// Cheap sanity gate: rejects selectors with characters that would make
    /// WebKit fail the WHOLE list compile. Real validation happens at compile.
    private static func isPlausibleSelector(_ selector: String) -> Bool {
        guard (2...600).contains(selector.count) else { return false }
        return selector.allSatisfy { ch in
            ch.isLetter || ch.isNumber || " .#>[]=:(),^~*|_-\"'+/\\%!&@$".contains(ch)
        }
    }
}
