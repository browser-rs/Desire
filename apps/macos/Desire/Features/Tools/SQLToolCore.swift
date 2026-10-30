import Foundation

/// 极简 SQL 美化：关键字大写 + 主要子句换行 + AND/OR 缩进。
/// 只处理常见的 SELECT/INSERT/UPDATE/DELETE 形态；字符串与注释原样保留。
nonisolated enum SQLToolCore {
    private static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "HAVING", "LIMIT",
        "OFFSET", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "ON", "AS", "AND", "OR",
        "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "UNION", "ALL", "DISTINCT",
        "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "PRIMARY", "KEY", "FOREIGN",
        "REFERENCES", "DEFAULT", "CASE", "WHEN", "THEN", "ELSE", "END", "ASC", "DESC",
        "COUNT", "SUM", "AVG", "MIN", "MAX", "EXISTS", "WITH",
    ]
    private static let majorClauses: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "INSERT", "UPDATE", "DELETE", "VALUES", "SET", "UNION", "CREATE", "ALTER", "DROP",
    ]
    private static let joinWords: Set<String> = ["JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL"]

    static func format(_ sql: String) -> String {
        let rawTokens = tokenize(sql)
        var output = ""
        var lastWasMajor = false
        for (index, token) in rawTokens.enumerated() {
            let upper = token.uppercased()
            let isMajor = majorClauses.contains(upper) || joinWords.contains(upper)
            if isMajor {
                if !output.isEmpty && !output.hasSuffix("\n") && !lastWasMajor { output += "\n" }
                if !output.isEmpty && lastWasMajor { output += " " }
                output += upper
                lastWasMajor = true
            } else if upper == "AND" || upper == "OR" {
                if !output.hasSuffix("\n") { output += "\n" }
                output += "  " + upper + " "
                lastWasMajor = false
            } else if token == "," {
                output += ", "
                lastWasMajor = false
            } else if ["=", "<", ">", "<=", ">=", "<>", "!=", "+", "-", "*", "/"].contains(token) {
                if !output.hasSuffix(" ") { output += " " }
                output += token + " "
                lastWasMajor = false
            } else if token == "(" || token == ")" {
                output += token
                lastWasMajor = false
            } else {
                let text = keywords.contains(upper) ? upper : token
                if !output.isEmpty, !output.hasSuffix(" "), !output.hasSuffix("\n"),
                   index > 0 {
                    let previous = rawTokens[index - 1]
                    if previous != "(" && previous != "." { output += " " }
                }
                output += text
                lastWasMajor = false
            }
        }
        // 压缩多余空格与空行
        var lines = output.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            lines[0] = "  " + lines[0]
            for index in lines.indices.dropFirst() { lines[index] = "  " + lines[index] }
        }
        return lines.joined(separator: "\n")
    }

    private static func tokenize(_ sql: String) -> [String] {
        var tokens: [String] = []
        let characters = Array(sql)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                let quote = character
                var literal = String(quote)
                index += 1
                while index < characters.count {
                    let current = characters[index]
                    literal.append(current)
                    if current == quote {
                        let next = index + 1
                        if next < characters.count, characters[next] == quote {
                            literal.append(characters[next])
                            index = next + 1
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                tokens.append(literal)
                continue
            }
            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                var comment = "--"
                index += 2
                while index < characters.count, characters[index] != "\n" {
                    comment.append(characters[index])
                    index += 1
                }
                tokens.append(comment)
                continue
            }
            if character.isLetter || character == "_" || character == "@" {
                var word = ""
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "_" || characters[index] == "@"
                        || characters[index] == "." {
                    word.append(characters[index])
                    index += 1
                }
                tokens.append(word)
                continue
            }
            if character.isNumber {
                var number = ""
                while index < characters.count,
                      characters[index].isNumber || characters[index] == "." {
                    number.append(characters[index])
                    index += 1
                }
                tokens.append(number)
                continue
            }
            let twoChar = String(characters[index...min(index + 1, characters.count - 1)])
            if ["<=", ">=", "<>", "!="].contains(twoChar) {
                tokens.append(twoChar)
                index += 2
                continue
            }
            tokens.append(String(character))
            index += 1
        }
        return tokens
    }
}
