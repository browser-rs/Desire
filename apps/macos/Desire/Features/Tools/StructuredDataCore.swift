import Foundation

/// 结构化数据转换（v0.8.33 开发批）：JSON ↔ plist（XML/binary）+ YAML→JSON
/// 常见子集。YAML 只接受块映射/序列/标量/行内数组；锚点、标签、块标量、
/// 行内对象一律明确报错，不做"猜"。纯 Foundation、进 tests/run.sh。
nonisolated enum StructuredDataCore {

    enum PlistFormat: String, CaseIterable, Identifiable, Sendable {
        case xml, binary
        var id: String { rawValue }
        var displayName: String { self == .xml ? "XML" : "Binary" }
    }

    enum ConversionError: LocalizedError {
        case emptyInput
        case invalidJSON
        case invalidPlist
        case invalidTopLevel
        case unsupportedValue(String)
        case invalidYAML(line: Int, reason: String)

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return String(localized: "Nothing to convert.")
            case .invalidJSON:
                return String(localized: "Invalid JSON.")
            case .invalidPlist:
                return String(localized: "Invalid property list.")
            case .invalidTopLevel:
                return String(localized: "The top level must be an object or an array.")
            case .unsupportedValue(let value):
                return String(localized: "This value cannot be stored in a property list: \(value)")
            case .invalidYAML(let line, let reason):
                return String(localized: "Invalid YAML at line \(line): \(reason)")
            }
        }
    }

    // MARK: - JSON → plist

    static func jsonToPlist(_ text: String, format: PlistFormat) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversionError.emptyInput }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            throw ConversionError.invalidJSON
        }
        let value = try plistValue(object)
        guard value is [String: Any] || value is [Any] else {
            throw ConversionError.invalidTopLevel
        }
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: value,
                format: format == .xml ? .xml : .binary,
                options: 0)
        } catch {
            throw ConversionError.unsupportedValue("\(object)")
        }
    }

    private static func plistValue(_ value: Any) throws -> Any {
        if value is NSNull {
            throw ConversionError.unsupportedValue("null")
        }
        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, item) in dictionary {
                output[key] = try plistValue(item)
            }
            return output
        }
        if let array = value as? [Any] {
            return try array.map { try plistValue($0) }
        }
        if value is String || value is NSNumber || value is Date || value is Data {
            return value
        }
        throw ConversionError.unsupportedValue("\(value)")
    }

    // MARK: - plist → JSON

    static func plistToJSON(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw ConversionError.emptyInput }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        } catch {
            throw ConversionError.invalidPlist
        }
        let value = jsonValue(object)
        do {
            let output = try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            return String(data: output, encoding: .utf8) ?? "{}"
        } catch {
            throw ConversionError.invalidPlist
        }
    }

    private static func jsonValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, item) in dictionary {
                output[key] = jsonValue(item)
            }
            return output
        }
        if let array = value as? [Any] {
            return array.map(jsonValue)
        }
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        if let data = value as? Data {
            return data.base64EncodedString()
        }
        if value is String || value is NSNumber || value is NSNull {
            return value
        }
        return String(describing: value)
    }

    // MARK: - YAML → JSON

    private struct YAMLLine {
        var number: Int
        var indent: Int
        var text: String
    }

    static func yamlToJSON(_ text: String) throws -> String {
        let lines = try yamlLines(text)
        guard !lines.isEmpty else { throw ConversionError.emptyInput }
        var index = 0
        let value = try parseYAMLBlock(lines, &index, indent: lines[0].indent)
        guard index >= lines.count else {
            throw ConversionError.invalidYAML(
                line: lines[index].number, reason: "unexpected content")
        }
        do {
            let output = try JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            return String(data: output, encoding: .utf8) ?? "{}"
        } catch {
            throw ConversionError.invalidYAML(line: lines[0].number, reason: "unrepresentable value")
        }
    }

    private static func yamlLines(_ text: String) throws -> [YAMLLine] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [YAMLLine] = []
        for (offset, raw) in normalized.components(separatedBy: "\n").enumerated() {
            let number = offset + 1
            var indent = 0
            var sawContent = false
            for character in raw {
                if character == " " {
                    indent += 1
                } else if character == "\t" {
                    throw ConversionError.invalidYAML(
                        line: number, reason: "tabs are not allowed for indentation")
                } else {
                    sawContent = true
                    break
                }
            }
            guard sawContent else { continue }
            var content = String(raw.dropFirst(indent))
            content = stripComment(content).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            if content == "---" || content == "..." { continue }
            if content.hasPrefix("%") {
                throw ConversionError.invalidYAML(line: number, reason: "directives are not supported")
            }
            result.append(YAMLLine(number: number, indent: indent, text: content))
        }
        return result
    }

    /// 去掉行内注释（引号内的 # 保留）；只认"前面是空白"的 #。
    private static func stripComment(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        var output = ""
        for character in text {
            if let current = quote {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" && current == "\"" {
                    escaped = true
                } else if character == current {
                    quote = nil
                }
                previous = character
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                output.append(character)
                previous = character
                continue
            }
            if character == "#", previous == nil || previous == " " || previous == "\t" {
                break
            }
            output.append(character)
            previous = character
        }
        return output
    }

    private static func parseYAMLBlock(_ lines: [YAMLLine], _ index: inout Int,
                                       indent: Int) throws -> Any {
        guard index < lines.count else {
            throw ConversionError.invalidYAML(line: 0, reason: "unexpected end of input")
        }
        let line = lines[index]
        if line.text == "-" || line.text.hasPrefix("- ") {
            return try parseYAMLSequence(lines, &index, indent: indent)
        }
        if mappingColon(line.text) != nil {
            return try parseYAMLMapping(lines, &index, indent: indent)
        }
        index += 1
        return try parseScalar(line.text, line: line.number)
    }

    private static func parseYAMLMapping(_ lines: [YAMLLine], _ index: inout Int,
                                         indent: Int) throws -> [String: Any] {
        var mapping: [String: Any] = [:]
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            guard line.indent == indent else {
                throw ConversionError.invalidYAML(
                    line: line.number, reason: "unexpected indentation")
            }
            guard let colon = mappingColon(line.text) else {
                throw ConversionError.invalidYAML(
                    line: line.number, reason: "expected key: value")
            }
            let key = try parseKey(String(line.text[..<colon]), line: line.number)
            let rest = String(line.text[line.text.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty {
                if index < lines.count, lines[index].indent > indent {
                    mapping[key] = try parseYAMLBlock(
                        lines, &index, indent: lines[index].indent)
                } else {
                    mapping[key] = NSNull()
                }
            } else {
                mapping[key] = try parseScalar(rest, line: line.number)
            }
        }
        return mapping
    }

    private static func parseYAMLSequence(_ lines: [YAMLLine], _ index: inout Int,
                                          indent: Int) throws -> [Any] {
        var result: [Any] = []
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            guard line.indent == indent else {
                throw ConversionError.invalidYAML(
                    line: line.number, reason: "unexpected indentation")
            }
            guard line.text == "-" || line.text.hasPrefix("- ") else { break }
            let rest = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
            index += 1
            if rest.isEmpty {
                if index < lines.count, lines[index].indent > indent {
                    result.append(try parseYAMLBlock(
                        lines, &index, indent: lines[index].indent))
                } else {
                    result.append(NSNull())
                }
                continue
            }
            if let colon = mappingColon(rest) {
                // 序列里的行内映射：`- key: value`；后续同级条目缩进 = 横线后两格。
                let mapIndent = indent + 2
                var mapping: [String: Any] = [:]
                let key = try parseKey(String(rest[..<colon]), line: line.number)
                let valueText = String(rest[rest.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                if valueText.isEmpty {
                    if index < lines.count, lines[index].indent > mapIndent {
                        mapping[key] = try parseYAMLBlock(
                            lines, &index, indent: lines[index].indent)
                    } else {
                        mapping[key] = NSNull()
                    }
                } else {
                    mapping[key] = try parseScalar(valueText, line: line.number)
                }
                if index < lines.count, lines[index].indent == mapIndent {
                    let more = try parseYAMLMapping(lines, &index, indent: mapIndent)
                    for (key, value) in more { mapping[key] = value }
                } else if index < lines.count, lines[index].indent > mapIndent {
                    throw ConversionError.invalidYAML(
                        line: lines[index].number, reason: "unexpected indentation")
                }
                result.append(mapping)
            } else {
                result.append(try parseScalar(rest, line: line.number))
            }
        }
        return result
    }

    private static func parseKey(_ text: String, line: Int) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ConversionError.invalidYAML(line: line, reason: "empty key")
        }
        if trimmed.hasPrefix("'") || trimmed.hasPrefix("\"") {
            return try parseQuoted(trimmed, line: line)
        }
        return trimmed
    }

    /// 找映射分隔冒号：引号外的、后面是空白或行尾的第一个 `:`。
    private static func mappingColon(_ text: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let current = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" && current == "\"" {
                    escaped = true
                } else if character == current {
                    quote = nil
                }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " || text[next] == "\t" {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseScalar(_ text: String, line: Int) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return NSNull() }
        if trimmed.hasPrefix("[") {
            guard trimmed.hasSuffix("]") else {
                throw ConversionError.invalidYAML(line: line, reason: "unterminated array")
            }
            let inner = String(trimmed.dropFirst().dropLast())
            let items = try splitFlowSequence(inner, line: line)
            return try items.map { try parseScalar($0, line: line) }
        }
        if trimmed.hasPrefix("{") {
            throw ConversionError.invalidYAML(
                line: line, reason: "inline mappings are not supported")
        }
        if trimmed.hasPrefix("|") || trimmed.hasPrefix(">") {
            throw ConversionError.invalidYAML(
                line: line, reason: "block scalars are not supported")
        }
        if trimmed.hasPrefix("&") || trimmed.hasPrefix("*") || trimmed.hasPrefix("!") {
            throw ConversionError.invalidYAML(
                line: line, reason: "anchors, aliases and tags are not supported")
        }
        if trimmed.hasPrefix("'") || trimmed.hasPrefix("\"") {
            return try parseQuoted(trimmed, line: line)
        }
        switch trimmed.lowercased() {
        case "null", "~": return NSNull()
        case "true": return true
        case "false": return false
        default: break
        }
        if let value = Int(trimmed) { return value }
        if let value = Double(trimmed), !trimmed.lowercased().contains("nan"),
           !trimmed.lowercased().contains("inf") {
            return value
        }
        return trimmed
    }

    private static func parseQuoted(_ text: String, line: Int) throws -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              first == last, first == "'" || first == "\"" else {
            throw ConversionError.invalidYAML(line: line, reason: "unterminated string")
        }
        let inner = String(text.dropFirst().dropLast())
        if first == "'" {
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        var output = ""
        var escaped = false
        for character in inner {
            if escaped {
                switch character {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "\\": output.append("\\")
                case "\"": output.append("\"")
                default: output.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func splitFlowSequence(_ text: String, line: Int) throws -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        for character in text {
            if let active = quote {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" && active == "\"" {
                    escaped = true
                } else if character == active {
                    quote = nil
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
                continue
            }
            if character == "[" || character == "{" {
                depth += 1
                current.append(character)
                continue
            }
            if character == "]" || character == "}" {
                depth -= 1
                current.append(character)
                continue
            }
            if character == ",", depth == 0 {
                items.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        guard quote == nil else {
            throw ConversionError.invalidYAML(line: line, reason: "unterminated string")
        }
        items.append(current)
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !trimmed.contains(where: \.isEmpty) else {
            throw ConversionError.invalidYAML(line: line, reason: "empty array element")
        }
        return trimmed
    }
}
