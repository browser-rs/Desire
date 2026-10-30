import Foundation

/// 正则测试的纯逻辑（Foundation NSRegularExpression，无脚本执行）。
nonisolated struct RegexMatchResult: Equatable, Sendable {
    var text: String
    var range: NSRange
    var groups: [String]
}

nonisolated struct RegexToolError: Error, Equatable, Sendable {
    var message: String
}

nonisolated enum RegexToolCore {
    static let maxMatches = 500

    static func matches(pattern: String, in text: String,
                        caseInsensitive: Bool = false,
                        multiline: Bool = false) -> Result<[RegexMatchResult], RegexToolError> {
        guard !pattern.isEmpty else { return .failure(RegexToolError(message: "Pattern is empty")) }
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multiline { options.insert(.anchorsMatchLines) }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            return .failure(RegexToolError(message: error.localizedDescription))
        }
        let ns = text as NSString
        let results = regex.matches(in: text, options: [],
                                    range: NSRange(location: 0, length: ns.length))
        let capped = results.prefix(maxMatches).map { match -> RegexMatchResult in
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            return RegexMatchResult(text: groups.first ?? "",
                                    range: match.range,
                                    groups: groups)
        }
        return .success(capped)
    }
}
