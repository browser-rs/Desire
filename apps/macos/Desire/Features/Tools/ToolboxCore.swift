import Foundation

/// 内置工具箱的纯逻辑（v0.8.27）：时间戳、进制、文本变换、编解码、JWT、颜色、
/// 密码生成——全部端上、无网络。UI（ToolsPageView）与测试共用这一套口径。
nonisolated struct ToolboxError: Error, Equatable, Sendable {
    var message: String
}

nonisolated enum ToolboxCore {

    // MARK: - 时间戳

    enum UnixUnit: String, Sendable {
        case seconds
        case milliseconds
    }

    /// 解析时间戳：13 位以上按毫秒，其余按秒；负数（1970 前）也支持。
    static func parseUnix(_ raw: String) -> (date: Date, unit: UnixUnit)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else { return nil }
        // 10 亿以上按毫秒更符合直觉（2001 年后的毫秒时间戳都 > 1e12）；
        // 用绝对值长度判定：>= 13 位数字按毫秒。
        let digits = trimmed.filter { $0.isNumber }.count
        let unit: UnixUnit = digits >= 13 ? .milliseconds : .seconds
        let seconds = unit == .milliseconds ? value / 1000 : value
        guard seconds > -62_135_596_800, seconds < 253_402_300_800 else { return nil }   // 0001–9999
        return (Date(timeIntervalSince1970: seconds), unit)
    }

    static func unixSeconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded()) }
    static func unixMilliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func formatted(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss (EEE)"
        return formatter.string(from: date)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - 进制

    static func detectBase(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("0x") { return 16 }
        if trimmed.hasPrefix("0b") { return 2 }
        if trimmed.hasPrefix("0o") { return 8 }
        return 10
    }

    /// 按指定进制解析整数（自动处理 0x/0b/0o 前缀；有符号）。
    static func parseInteger(_ raw: String, base: Int? = nil) -> Int64? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var negative = false
        if trimmed.hasPrefix("-") { negative = true; trimmed.removeFirst() }
        else if trimmed.hasPrefix("+") { trimmed.removeFirst() }
        var resolved = base ?? 10
        if trimmed.hasPrefix("0x") { resolved = 16; trimmed.removeFirst(2) }
        else if trimmed.hasPrefix("0b") { resolved = 2; trimmed.removeFirst(2) }
        else if trimmed.hasPrefix("0o") { resolved = 8; trimmed.removeFirst(2) }
        guard (2...36).contains(resolved), !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let magnitude = Int64(cleaned, radix: resolved) else { return nil }
        return negative ? -magnitude : magnitude
    }

    struct Bases: Equatable, Sendable {
        var decimal: String
        var hexadecimal: String
        var binary: String
        var octal: String
    }

    static func bases(for value: Int64) -> Bases {
        Bases(decimal: String(value),
              hexadecimal: "0x" + String(value, radix: 16, uppercase: true),
              binary: "0b" + String(value, radix: 2),
              octal: "0o" + String(value, radix: 8))
    }

    // MARK: - 文本变换

    enum LineMode: String, CaseIterable, Sendable {
        case sort
        case sortDescending
        case dedupe
        case reverse
        case numbered
    }

    static func upper(_ text: String) -> String { text.uppercased() }
    static func lower(_ text: String) -> String { text.lowercased() }

    static func titleCase(_ text: String) -> String {
        text.capitalized(with: Locale(identifier: "en_US_POSIX"))
    }

    static func snakeCase(_ text: String) -> String {
        words(in: text).map { $0.lowercased() }.joined(separator: "_")
    }

    static func kebabCase(_ text: String) -> String {
        words(in: text).map { $0.lowercased() }.joined(separator: "-")
    }

    /// 拆词：空白/下划线/连字符/驼峰边界，统一转小写前先分开。
    static func words(in text: String) -> [String] {
        var normalized = ""
        var previousWasSeparator = true
        for character in text {
            if character == "_" || character == "-" || character.isWhitespace {
                if !previousWasSeparator { normalized.append(" ") }
                previousWasSeparator = true
                continue
            }
            if character.isUppercase, !previousWasSeparator,
               let last = normalized.last, last.isLowercase {
                normalized.append(" ")
            }
            normalized.append(character)
            previousWasSeparator = false
        }
        return normalized.split(whereSeparator: { $0 == " " }).map(String.init)
    }

    static func processLines(_ text: String, mode: LineMode) -> String {
        let lines = text.components(separatedBy: "\n")
        switch mode {
        case .sort:
            return lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case .sortDescending:
            return lines.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                .joined(separator: "\n")
        case .dedupe:
            var seen = Set<String>()
            return lines.filter { line in
                let key = line.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return true }
                return seen.insert(key).inserted
            }.joined(separator: "\n")
        case .reverse:
            return lines.reversed().joined(separator: "\n")
        case .numbered:
            return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        }
    }

    static func stats(_ text: String) -> (characters: Int, words: Int, lines: Int) {
        let characters = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        return (characters, words, lines)
    }

    // MARK: - 编解码

    static func base64Encode(_ text: String, urlSafe: Bool = false) -> String {
        var encoded = Data(text.utf8).base64EncodedString()
        guard urlSafe else { return encoded }
        encoded = encoded.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded
    }

    static func base64Decode(_ raw: String) -> Result<String, ToolboxError> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = text.count % 4
        if padding > 0 { text += String(repeating: "=", count: 4 - padding) }
        guard let data = Data(base64Encoded: text, options: []) else {
            return .failure(ToolboxError(message: "Not valid base64"))
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return .failure(ToolboxError(message: "Decoded bytes are not UTF-8 text"))
        }
        return .success(string)
    }

    static func urlEncode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func urlDecode(_ text: String) -> Result<String, ToolboxError> {
        guard let decoded = text.removingPercentEncoding else {
            return .failure(ToolboxError(message: "Malformed percent-encoding"))
        }
        return .success(decoded)
    }

    // MARK: - JWT

    static func base64URLDecode(_ raw: String) -> Data? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = text.count % 4
        if padding > 0 { text += String(repeating: "=", count: 4 - padding) }
        return Data(base64Encoded: text)
    }

    /// 解出 JWT 的 header / payload（不验签——只做"看清内容"）。
    static func jwtParts(_ token: String) -> (header: String, payload: String, expiry: Date?)? {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        guard let headerData = base64URLDecode(parts[0]),
              let payloadData = base64URLDecode(parts[1]) else { return nil }
        func pretty(_ data: Data) -> String? {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let prettyData = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: prettyData, encoding: .utf8) else { return nil }
            return text
        }
        guard let header = pretty(headerData), let payload = pretty(payloadData) else { return nil }
        var expiry: Date?
        if let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
           let exp = object["exp"] as? Double {
            expiry = Date(timeIntervalSince1970: exp)
        }
        return (header, payload, expiry)
    }

    // MARK: - 颜色

    static func parseHexColor(_ raw: String) -> (red: Int, green: Int, blue: Int, alpha: Double)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
              text.allSatisfy({ $0.isHexDigit }) else { return nil }
        func component(_ start: Int) -> Int {
            let begin = text.index(text.startIndex, offsetBy: start)
            let end = text.index(begin, offsetBy: 2)
            return Int(text[begin..<end], radix: 16) ?? 0
        }
        let alpha = text.count == 8 ? Double(component(6)) / 255.0 : 1.0
        return (component(0), component(2), component(4), alpha)
    }

    static func hexColor(red: Int, green: Int, blue: Int, alpha: Double = 1) -> String {
        let r = min(max(red, 0), 255)
        let g = min(max(green, 0), 255)
        let b = min(max(blue, 0), 255)
        if alpha >= 0.999 { return String(format: "#%02X%02X%02X", r, g, b) }
        return String(format: "#%02X%02X%02X%02X", r, g, b,
                      min(max(Int((alpha * 255).rounded()), 0), 255))
    }

    // MARK: - 密码

    static func generatePassword(length: Int = 20, useDigits: Bool = true,
                                 useSymbols: Bool = true, useUppercase: Bool = true,
                                 useAvoidAmbiguous: Bool = false) -> String {
        var lower = "abcdefghijklmnopqrstuvwxyz"
        if useAvoidAmbiguous { lower = lower.filter { !"ilo".contains($0) } }
        let upper = useUppercase ? lower.uppercased() : ""
        var digits = useDigits ? "0123456789" : ""
        if useAvoidAmbiguous { digits = digits.filter { !"01".contains($0) } }
        let symbols = useSymbols ? "!@#$%^&*()-_=+[]{};:,.?/" : ""
        let pool = lower + upper + digits + symbols
        guard !pool.isEmpty else { return "" }
        let target = max(4, min(length, 128))
        var result = ""
        var generator = SystemRandomNumberGenerator()
        // 先保证每类至少一个，再补足长度（需求类别集合非空时）。
        let required = [lower, upper, digits, symbols].filter { !$0.isEmpty }
            .compactMap { $0.randomElement(using: &generator) }
        for character in required where result.count < target {
            result.append(character)
        }
        while result.count < target {
            result.append(pool.randomElement(using: &generator) ?? "a")
        }
        return String(result.shuffled(using: &generator))
    }

    /// 0（空）… 4（很强）。
    static func passwordStrength(_ password: String) -> Int {
        guard !password.isEmpty else { return 0 }
        var score = 0
        if password.count >= 8 { score += 1 }
        if password.count >= 14 { score += 1 }
        if password.contains(where: { $0.isLowercase }) && password.contains(where: { $0.isUppercase }) {
            score += 1
        }
        if password.contains(where: { $0.isNumber })
            && password.contains(where: { !$0.isLetter && !$0.isNumber }) {
            score += 1
        }
        return min(score, 4)
    }
}
