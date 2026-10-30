import Foundation

/// JSON 语法着色的纯逻辑（v0.8.26）：返回 token 的 UTF-16 区间与类别，
/// 视图层据此给 NSAttributedString 上色（核心不依赖 AppKit，进 harness）。
nonisolated struct JSONToken: Equatable, Sendable {
    enum Kind: String, Sendable {
        case key
        case string
        case number
        case literal
    }

    var kind: Kind
    /// UTF-16 偏移（NSAttributedString 口径）。
    var location: Int
    var length: Int
}

nonisolated enum JSONSyntaxHighlightCore {
    static func tokens(in text: String) -> [JSONToken] {
        let units = Array(text.utf16)
        var tokens: [JSONToken] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 34 {   // '"'
                let start = index
                index += 1
                var escaped = false
                while index < units.count {
                    let c = units[index]
                    if escaped {
                        escaped = false
                    } else if c == 92 {   // '\'
                        escaped = true
                    } else if c == 34 {
                        index += 1
                        break
                    }
                    index += 1
                }
                var cursor = index
                while cursor < units.count, isWhitespace(units[cursor]) { cursor += 1 }
                let kind: JSONToken.Kind =
                    (cursor < units.count && units[cursor] == 58) ? .key : .string   // ':'
                tokens.append(JSONToken(kind: kind, location: start, length: index - start))
                continue
            }
            if unit == 45 || (unit >= 48 && unit <= 57) {   // '-' or digit
                let start = index
                index += 1
                while index < units.count {
                    let c = units[index]
                    if (c >= 48 && c <= 57) || c == 46 || c == 101 || c == 69
                        || c == 43 || c == 45 {
                        index += 1
                    } else {
                        break
                    }
                }
                tokens.append(JSONToken(kind: .number, location: start, length: index - start))
                continue
            }
            if (unit >= 97 && unit <= 122) || (unit >= 65 && unit <= 90) {   // letters
                let start = index
                index += 1
                while index < units.count {
                    let c = units[index]
                    if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) { index += 1 } else { break }
                }
                tokens.append(JSONToken(kind: .literal, location: start, length: index - start))
                continue
            }
            index += 1
        }
        return tokens
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13
    }
}
