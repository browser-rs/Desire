import Foundation

/// JSONPath 子集（v0.8.33 开发批）：`$.a.b[0]`、`[*]`、`.*`、`..key`
/// 与引号键 `$['a.b']`。纯 Foundation、进 tests/run.sh。
nonisolated enum JSONPathCore {

    private enum Token {
        case key(String)
        case index(Int)
        case wildcard
        case recursiveKey(String)
    }

    /// 查询；语法错误返回 nil，合法但无命中返回空数组。
    static func query(_ root: Any, path: String) -> [Any]? {
        guard let tokens = parse(path) else { return nil }
        var nodes: [Any] = [root]
        for token in tokens {
            var next: [Any] = []
            for node in nodes {
                switch token {
                case .key(let key):
                    if let dictionary = node as? [String: Any],
                       let value = dictionary[key] {
                        next.append(value)
                    }
                case .index(let index):
                    if let array = node as? [Any] {
                        let resolved = index < 0 ? array.count + index : index
                        if resolved >= 0 && resolved < array.count {
                            next.append(array[resolved])
                        }
                    }
                case .wildcard:
                    if let array = node as? [Any] {
                        next.append(contentsOf: array)
                    } else if let dictionary = node as? [String: Any] {
                        for key in dictionary.keys.sorted() {
                            if let value = dictionary[key] { next.append(value) }
                        }
                    }
                case .recursiveKey(let key):
                    collect(key: key, from: node, into: &next)
                }
            }
            nodes = next
        }
        return nodes
    }

    /// 结果 → JSON 文本（单条输出原值，多条输出数组）。
    static func display(_ values: [Any]) -> String? {
        if values.isEmpty { return "[]" }
        let payload: Any = values.count == 1 ? values[0] : values
        let scalar = payload is String || payload is NSNumber || payload is NSNull
        guard scalar || JSONSerialization.isValidJSONObject(payload) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 路径解析

    private static func parse(_ path: String) -> [Token]? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        guard characters.first == "$" else { return nil }
        var index = 1
        var tokens: [Token] = []
        while index < characters.count {
            let character = characters[index]
            if character == "." {
                if index + 1 < characters.count, characters[index + 1] == "." {
                    index += 2
                    guard let (name, next) = readName(characters, from: index) else { return nil }
                    tokens.append(.recursiveKey(name))
                    index = next
                } else {
                    index += 1
                    if index < characters.count, characters[index] == "*" {
                        tokens.append(.wildcard)
                        index += 1
                    } else {
                        guard let (name, next) = readName(characters, from: index) else {
                            return nil
                        }
                        tokens.append(.key(name))
                        index = next
                    }
                }
            } else if character == "[" {
                guard let close = matchingBracket(characters, from: index) else { return nil }
                let inner = String(characters[(index + 1)..<close])
                    .trimmingCharacters(in: .whitespaces)
                if inner == "*" {
                    tokens.append(.wildcard)
                } else if let value = Int(inner) {
                    tokens.append(.index(value))
                } else if (inner.hasPrefix("'") && inner.hasSuffix("'"))
                            || (inner.hasPrefix("\"") && inner.hasSuffix("\"")) {
                    let name = String(inner.dropFirst().dropLast())
                    guard !name.isEmpty else { return nil }
                    tokens.append(.key(name))
                } else {
                    return nil
                }
                index = close + 1
            } else {
                return nil
            }
        }
        return tokens
    }

    private static func readName(_ characters: [Character], from start: Int) -> (String, Int)? {
        var index = start
        var name = ""
        while index < characters.count {
            let character = characters[index]
            if character == "." || character == "[" || character == "]" { break }
            if character.isWhitespace { return nil }
            name.append(character)
            index += 1
        }
        return name.isEmpty ? nil : (name, index)
    }

    private static func matchingBracket(_ characters: [Character], from start: Int) -> Int? {
        var quote: Character?
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "]" {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func collect(key: String, from node: Any, into result: inout [Any]) {
        if let dictionary = node as? [String: Any] {
            if let value = dictionary[key] { result.append(value) }
            for childKey in dictionary.keys.sorted() {
                if let value = dictionary[childKey] {
                    collect(key: key, from: value, into: &result)
                }
            }
        } else if let array = node as? [Any] {
            for item in array {
                collect(key: key, from: item, into: &result)
            }
        }
    }
}
