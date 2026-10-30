import Foundation

/// 正则测试的纯逻辑（Foundation NSRegularExpression，无脚本执行）。
nonisolated struct RegexMatchResult: Equatable, Sendable {
    var text: String
    var range: NSRange
    var groups: [String]
}

nonisolated enum RegexToolCore {
    static let maxMatches = 500

    /// 正则替换：template 支持 $1/$2 捕获组引用（NSRegularExpression 模板语法）。
    static func replace(pattern: String, template: String, in text: String,
                        caseInsensitive: Bool = false,
                        multiline: Bool = false) -> Result<String, ToolboxError> {
        guard !pattern.isEmpty else { return .failure(ToolboxError(message: "Pattern is empty")) }
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multiline { options.insert(.anchorsMatchLines) }
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(text.startIndex..., in: text)
            return .success(regex.stringByReplacingMatches(in: text, options: [],
                                                           range: range,
                                                           withTemplate: template))
        } catch {
            return .failure(ToolboxError(message: error.localizedDescription))
        }
    }

    static func matches(pattern: String, in text: String,
                        caseInsensitive: Bool = false,
                        multiline: Bool = false) -> Result<[RegexMatchResult], ToolboxError> {
        guard !pattern.isEmpty else { return .failure(ToolboxError(message: "Pattern is empty")) }
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if caseInsensitive { options.insert(.caseInsensitive) }
        if multiline { options.insert(.anchorsMatchLines) }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            return .failure(ToolboxError(message: error.localizedDescription))
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
