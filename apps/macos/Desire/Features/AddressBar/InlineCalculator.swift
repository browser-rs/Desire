import Foundation

/// 地址栏内联计算器（v0.8.6）：安全数学表达式求值。
/// 支持 + - * / % ( ) 和百分比；不使用 eval，手写递归下降解析。
/// Foundation-only，进 harness。
nonisolated enum InlineCalculator {
    static func evaluate(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
        guard !cleaned.isEmpty else { return nil }
        let operators: Set<Character> = ["+", "-", "*", "/", "%", "(", ")"]
        guard cleaned.contains(where: { operators.contains($0) }) else { return nil }
        guard let result = parseExpression(cleaned) else { return nil }
        if result == result.rounded() && abs(result) < 1e15 {
            return String(format: "%lld", Int64(result))
        }
        return String(format: "%.6g", result)
    }

    private static func parseExpression(_ text: String) -> Double? {
        var chars = Array(text)
        var pos = 0
        let result = parseAddSub(&chars, &pos)
        guard pos == chars.count else { return nil }
        return result
    }

    private static func parseAddSub(_ chars: inout [Character], _ pos: inout Int) -> Double? {
        guard var left = parseMulDiv(&chars, &pos) else { return nil }
        while pos < chars.count {
            let op = chars[pos]
            if op == "+" || op == "-" {
                pos += 1
                guard let right = parseMulDiv(&chars, &pos) else { return nil }
                left = op == "+" ? left + right : left - right
            } else { break }
        }
        return left
    }

    private static func parseMulDiv(_ chars: inout [Character], _ pos: inout Int) -> Double? {
        guard var left = parsePrimary(&chars, &pos) else { return nil }
        while pos < chars.count {
            let op = chars[pos]
            if op == "*" || op == "/" {
                pos += 1
                guard let right = parsePrimary(&chars, &pos) else { return nil }
                if op == "*" { left *= right }
                else {
                    guard right != 0 else { return nil }
                    left /= right
                }
            } else if op == "%" {
                pos += 1
                left = left / 100.0
            } else { break }
        }
        return left
    }

    private static func parsePrimary(_ chars: inout [Character], _ pos: inout Int) -> Double? {
        guard pos < chars.count else { return nil }
        let char = chars[pos]
        if char == "(" {
            pos += 1
            guard let result = parseAddSub(&chars, &pos) else { return nil }
            guard pos < chars.count, chars[pos] == ")" else { return nil }
            pos += 1
            return result
        }
        if char == "-" {
            pos += 1
            guard let value = parsePrimary(&chars, &pos) else { return nil }
            return -value
        }
        var numStr = ""
        while pos < chars.count, chars[pos].isNumber || chars[pos] == "." {
            numStr.append(chars[pos])
            pos += 1
        }
        return Double(numStr)
    }
}
