import Foundation

/// 科学计算器的表达式求值（递归下降；不执行任何脚本，纯算术）。
/// 支持 + - * / % ^、括号、一元正负、常量 pi/e，
/// 函数 sqrt/abs/sin/cos/tan/ln/log/exp/floor/ceil/round。
nonisolated struct ExpressionError: Error, Equatable, Sendable {
    var message: String
}

nonisolated enum ExpressionParser {
    static func evaluate(_ expression: String) -> Result<Double, ExpressionError> {
        do {
            var parser = Parser(tokens: try Tokenizer.tokenize(expression))
            let value = try parser.parseExpression()
            guard parser.isAtEnd else { throw ParseError("Unexpected token") }
            guard value.isFinite else { throw ParseError("Result is not finite") }
            return .success(value)
        } catch let error as ParseError {
            return .failure(ExpressionError(message: error.message))
        } catch {
            return .failure(ExpressionError(message: "Invalid expression"))
        }
    }

    private struct ParseError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(Character)
    }

    private enum Tokenizer {
        static func tokenize(_ text: String) throws -> [Token] {
            var tokens: [Token] = []
            let characters = Array(text)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace {
                    index += 1
                    continue
                }
                if character.isNumber || character == "." {
                    var literal = ""
                    while index < characters.count,
                          characters[index].isNumber || characters[index] == "." {
                        literal.append(characters[index])
                        index += 1
                    }
                    guard let value = Double(literal) else {
                        throw ParseError("Invalid number: \(literal)")
                    }
                    tokens.append(.number(value))
                    continue
                }
                if character.isLetter {
                    var name = ""
                    while index < characters.count, characters[index].isLetter {
                        name.append(characters[index])
                        index += 1
                    }
                    tokens.append(.identifier(name.lowercased()))
                    continue
                }
                if "+-*/%^(),".contains(character) {
                    tokens.append(.op(character))
                    index += 1
                    continue
                }
                throw ParseError("Unexpected character: \(character)")
            }
            return tokens
        }
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var isAtEnd: Bool { index >= tokens.count }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while let op = currentOperator(), op == "+" || op == "-" {
                index += 1
                let rhs = try parseTerm()
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() throws -> Double {
            var value = try parseUnary()
            while let op = currentOperator(), op == "*" || op == "/" || op == "%" {
                index += 1
                let rhs = try parseUnary()
                switch op {
                case "*": value *= rhs
                case "/":
                    guard rhs != 0 else { throw ParseError("Division by zero") }
                    value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func parseUnary() throws -> Double {
            if let op = currentOperator(), op == "+" || op == "-" {
                index += 1
                let value = try parseUnary()
                return op == "-" ? -value : value
            }
            return try parsePower()
        }

        mutating func parsePower() throws -> Double {
            let base = try parsePrimary()
            if let op = currentOperator(), op == "^" {
                index += 1
                let exponent = try parseUnary()
                return pow(base, exponent)
            }
            return base
        }

        mutating func parsePrimary() throws -> Double {
            guard index < tokens.count else { throw ParseError("Unexpected end of expression") }
            let token = tokens[index]
            switch token {
            case .number(let value):
                index += 1
                return value
            case .identifier(let name):
                index += 1
                if name == "pi" { return Double.pi }
                if name == "e" { return M_E }
                if let op = currentOperator(), op == "(" {
                    index += 1
                    let argument = try parseExpression()
                    guard let close = currentOperator(), close == ")" else {
                        throw ParseError("Missing ')' after \(name)")
                    }
                    index += 1
                    return try apply(name, argument)
                }
                throw ParseError("Unknown identifier: \(name)")
            case .op(let op):
                if op == "(" {
                    index += 1
                    let value = try parseExpression()
                    guard let close = currentOperator(), close == ")" else {
                        throw ParseError("Missing ')'")
                    }
                    index += 1
                    return value
                }
                throw ParseError("Unexpected operator: \(op)")
            }
        }

        private func apply(_ name: String, _ value: Double) throws -> Double {
            switch name {
            case "sqrt":
                guard value >= 0 else { throw ParseError("sqrt of a negative number") }
                return sqrt(value)
            case "abs": return abs(value)
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "tan": return tan(value)
            case "ln":
                guard value > 0 else { throw ParseError("ln of a non-positive number") }
                return log(value)
            case "log":
                guard value > 0 else { throw ParseError("log of a non-positive number") }
                return log10(value)
            case "exp": return exp(value)
            case "floor": return floor(value)
            case "ceil": return ceil(value)
            case "round": return value.rounded()
            default: throw ParseError("Unknown function: \(name)")
            }
        }

        private func currentOperator() -> Character? {
            guard index < tokens.count, case .op(let op) = tokens[index] else { return nil }
            return op
        }
    }
}
