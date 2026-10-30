import CoreFoundation
import Foundation

/// JSON 格式化/校验/转换的纯逻辑（v0.8.26 办公增强）：查看器、Agent 工具与
/// 桥端点共用同一套口径（解析错误带行列、JSONL 逐行、表格化导出）。
nonisolated enum JSONFormatterCore {

    struct Failure: Equatable, Error {
        var message: String
        var line: Int
        var column: Int
    }

    struct Table: Equatable {
        var header: [String]
        var rows: [[String]]
    }

    // MARK: - 解析

    /// 解析任意 JSON 文本（允许顶层标量）。错误信息带行列。
    static func parse(_ text: String) -> Result<Any, Failure> {
        let data = Data(text.utf8)
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .success(object)
        } catch let error as NSError {
            return .failure(failure(from: error, text: text))
        }
    }

    static func validate(_ text: String) -> Failure? {
        switch parse(text) {
        case .success: return nil
        case .failure(let failure): return failure
        }
    }

    /// JSONL：逐行解析（空行跳过）；返回每行对象与首个错误（带物理行号）。
    static func parseJSONL(_ text: String) -> Result<[Any], Failure> {
        var out: [Any] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch parse(String(trimmed)) {
            case .success(let object):
                out.append(object)
            case .failure(var failure):
                failure.line = index + 1
                failure.message = "line \(index + 1): \(failure.message)"
                return .failure(failure)
            }
        }
        return .success(out)
    }

    /// 是否像 JSONL（多行且逐行都能解析）。
    static func looksLikeJSONL(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return false }
        return lines.allSatisfy { line in
            guard line.hasPrefix("{") || line.hasPrefix("[") else { return false }
            if case .success = parse(line) { return true }
            return false
        }
    }

    // MARK: - 格式化

    /// 美化 / 压缩 / 键排序；`jsonl` 为真时逐行处理。
    static func format(_ text: String, indent: Int = 2, sortKeys: Bool = false,
                       minify: Bool = false, jsonl: Bool = false) -> Result<String, Failure> {
        if jsonl || looksLikeJSONL(text) {
            switch parseJSONL(text) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let objects):
                var lines: [String] = []
                for object in objects {
                    guard let line = serialized(object, indent: indent, sortKeys: sortKeys,
                                                minify: minify) else {
                        return .failure(Failure(message: "cannot serialize value",
                                                line: 0, column: 0))
                    }
                    lines.append(line)
                }
                return .success(lines.joined(separator: "\n"))
            }
        }
        switch parse(text) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let object):
            guard let out = serialized(object, indent: indent, sortKeys: sortKeys,
                                       minify: minify) else {
                return .failure(Failure(message: "cannot serialize value", line: 0, column: 0))
            }
            return .success(out)
        }
    }

    /// JSON → 表格（数组对象取首见键序；数组数组原样；单对象 → key/value）。
    static func table(from object: Any) -> Table? {
        if let array = object as? [Any] {
            if array.isEmpty { return nil }
            if let dicts = array as? [[String: Any]] {
                // JSONSerialization 的字典不保序——表头统一按字母序，
                // 同一份数据的列顺序跨平台/跨次稳定。
                var union = Set<String>()
                for dict in dicts { union.formUnion(dict.keys) }
                let keys = union.sorted()
                let rows = dicts.map { dict in
                    keys.map { cellText(dict[$0]) }
                }
                return Table(header: keys, rows: rows)
            }
            if array.allSatisfy({ $0 is [Any] }) {
                let rows = (array as? [[Any]] ?? []).map { $0.map(cellText) }
                let width = rows.map(\.count).max() ?? 0
                let header = (0..<width).map { "Column \($0 + 1)" }
                return Table(header: header, rows: rows)
            }
            // 标量数组 → 单列
            return Table(header: ["Value"], rows: array.map { [cellText($0)] })
        }
        if let dict = object as? [String: Any] {
            return Table(header: ["Key", "Value"],
                         rows: dict.keys.sorted().map { [$0, cellText(dict[$0])] })
        }
        return nil
    }

    /// JSON → CSV（RFC 4180 引号规则）；无法表格化返回 nil。
    static func csv(from object: Any) -> String? {
        guard let table = table(from: object) else { return nil }
        return csvText(table)
    }

    static func csvText(_ table: Table) -> String {
        var lines: [String] = [table.header.map(csvField).joined(separator: ",")]
        for row in table.rows {
            var cells = row
            if cells.count < table.header.count {
                cells += Array(repeating: "", count: table.header.count - cells.count)
            }
            lines.append(cells.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// 值 → 单元格文本（字符串原样；null 空；复合类型压缩 JSON）。
    static func cellText(_ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            // Bool 在 JSONSerialization 里也是 NSNumber——按 CFBoolean 判定。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    // MARK: - 内部

    static func serialized(_ object: Any, indent: Int, sortKeys: Bool, minify: Bool) -> String? {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        if !minify {
            options.insert(.prettyPrinted)
            options.insert(.withoutEscapingSlashes)
        }
        if sortKeys { options.insert(.sortedKeys) }
        guard JSONSerialization.isValidJSONObject(object) || isFragment(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard !minify, indent != 2 else { return text }
        // JSONSerialization 固定 2 空格缩进；其他档位按行首空格等比缩放。
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let spaces = line.prefix { $0 == " " }.count
            guard spaces > 0 else { return String(line) }
            let scaled = spaces / 2 * indent
            return String(repeating: " ", count: scaled) + line.dropFirst(spaces)
        }.joined(separator: "\n")
    }

    private static func isFragment(_ object: Any) -> Bool {
        !(object is [Any]) && !(object is [String: Any])
    }

    static func failure(from error: NSError, text: String) -> Failure {
        let debug = (error.userInfo[NSDebugDescriptionErrorKey] as? String)
            ?? error.localizedDescription
        let (line, column) = parseLocation(from: debug, text: text)
        // 去掉 Foundation 多余的前后缀，保留有用描述。
        let cleaned = debug
            .replacingOccurrences(of: "JSON text did not start with array or object and option to allow fragments not set.", with: "not valid JSON")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Failure(message: cleaned, line: line, column: column)
    }

    /// 从 Foundation 的描述里抠 "line X, column Y"（没有就按 offset/unknown）。
    static func parseLocation(from debug: String, text: String) -> (Int, Int) {
        let pattern = "line\\s+(\\d+),\\s*column\\s+(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: debug, range: NSRange(debug.startIndex..., in: debug)),
           match.numberOfRanges == 3,
           let lineRange = Range(match.range(at: 1), in: debug),
           let columnRange = Range(match.range(at: 2), in: debug),
           let line = Int(debug[lineRange]),
           let column = Int(debug[columnRange]) {
            return (line, column)
        }
        return (0, 0)
    }

    private static func csvField(_ value: String) -> String {
        let needsQuote = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuote else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
