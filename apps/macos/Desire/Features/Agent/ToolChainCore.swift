import Foundation

/// 工具链的纯逻辑核心（v0.8.51 批 2）。Foundation-only、进 tests/run.sh。
///
/// `runToolChain` 让模型**一次调用**串起多个工具（最多 10 步），避免长回合里
/// "一步一回合"的来回。本文件负责可测的部分：
/// - 步骤解析（`steps: [{tool, args}]`）；
/// - **变量替换**：`$prev`（上一步结果原文）、`$prev.field`（上一步结果若是 JSON
///   对象则取字段）、`$1..$9`（第 n 步结果）；替换发生在参数**字符串值**里
///   （整值或混排），嵌套对象/数组递归处理；
/// - 结果摘要（每步成功/失败/耗时 + 截断片段 + 总体结论）。
nonisolated enum ToolChainCore {

    struct Step: Equatable {
        var tool: String
        /// 参数表；变量替换后才交给真正的工具。用 Any 是因为工具参数本身是
        /// JSON 值（字符串/数字/布尔/对象/数组）。
        var args: [String: Any]

        static func == (lhs: Step, rhs: Step) -> Bool {
            lhs.tool == rhs.tool
        }
    }

    struct Outcome: Equatable {
        var index: Int          // 1-based
        var tool: String
        var result: String
        var seconds: Double
        var failed: Bool
    }

    static let maxSteps = 10
    /// 单步结果在摘要里的截断长度。
    static let snippetLimit = 400

    // MARK: - 解析

    static func parseSteps(_ raw: Any?) -> [Step] {
        guard let items = raw as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let tool = (item["tool"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty else { return nil }
            let args = item["args"] as? [String: Any] ?? [:]
            return Step(tool: tool, args: args)
        }
    }

    /// 失败判据与全局约定一致：结果以 `Error: ` 开头。
    static func isFailure(_ result: String) -> Bool {
        result.hasPrefix("Error:")
    }

    // MARK: - 变量替换

    /// 参数表递归替换（字符串值里的变量；键名不替换）。
    static func substitute(args: [String: Any], results: [String]) -> [String: Any] {
        args.mapValues { substitute(value: $0, results: results) }
    }

    static func substitute(value: Any, results: [String]) -> Any {
        switch value {
        case let text as String:
            return substitute(text: text, results: results)
        case let dict as [String: Any]:
            return dict.mapValues { substitute(value: $0, results: results) }
        case let array as [Any]:
            return array.map { substitute(value: $0, results: results) }
        default:
            return value
        }
    }

    static func substitute(text: String, results: [String]) -> String {
        guard text.contains("$") else { return text }
        let pattern = #"\$(prev(\.[A-Za-z0-9_]+)?|[1-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var output = ""
        var cursor = 0
        for match in matches {
            // 每轮都用**本次匹配**的区间切片，绝不缓存跨替换的 range。
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = ns.substring(with: match.range)
            output += replacement(for: token, results: results)
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    static func replacement(for token: String, results: [String]) -> String {
        if token == "$prev" { return results.last ?? "" }
        if token.hasPrefix("$prev.") {
            let field = String(token.dropFirst("$prev.".count))
            guard let last = results.last,
                  let data = last.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object[field] else { return "" }
            return stringify(value)
        }
        if let index = Int(token.dropFirst()), index >= 1, index <= results.count {
            return results[index - 1]
        }
        return ""
    }

    static func stringify(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let dict = value as? [String: Any] ?? (value as? [Any]).map({ ["items": $0] }) {
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return String(describing: value)
    }

    // MARK: - 摘要

    /// 每步一行 + 总体结论。`stopped` = 因失败提前停下（整体应是 `Error:`）。
    static func summarize(outcomes: [Outcome], onError: String, stopped: Bool) -> String {
        var lines: [String] = []
        lines.append("Chain: \(outcomes.count) step(s), onError=\(onError)")
        for outcome in outcomes {
            let mark = outcome.failed ? "✗" : "✓"
            let snippet = outcome.result
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ⏎ ")
            let clipped = snippet.count > snippetLimit
                ? String(snippet.prefix(snippetLimit)) + "…"
                : snippet
            lines.append(String(format: "[%d] %@ %@ %.2fs — %@",
                                outcome.index, outcome.tool, mark, outcome.seconds, clipped))
        }
        let succeeded = outcomes.filter { !$0.failed }.count
        let failed = outcomes.count - succeeded
        if stopped, let firstFailure = outcomes.first(where: \.failed) {
            lines.append("Result: stopped at step \(firstFailure.index) — \(succeeded) succeeded, \(failed) failed")
        } else if failed > 0 {
            lines.append("Result: \(succeeded) succeeded, \(failed) failed (continued)")
        } else {
            lines.append("Result: \(succeeded) succeeded")
        }
        return lines.joined(separator: "\n")
    }

    /// 整体前缀：提前停下（onError=stop）时用 `Error:`，让模型看到失败。
    static func overallPrefix(stopped: Bool) -> String {
        stopped ? "Error: chain stopped — " : ""
    }
}
