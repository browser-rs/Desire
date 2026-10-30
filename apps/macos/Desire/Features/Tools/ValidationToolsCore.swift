import Foundation

/// 中国居民身份证校验（18 位；只做格式/校验位/生日/性别解析，不联网）。
nonisolated enum IDCardCore {
    struct Info: Equatable, Sendable {
        var birthDate: String
        var gender: String
        var checkDigit: String
    }

    static let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    static let checkMap = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]

    static func validate(_ raw: String) -> Result<Info, ToolboxError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.count == 18 else { return .failure(ToolboxError(message: "ID number must be 18 characters")) }
        let characters = Array(text)
        guard characters.prefix(17).allSatisfy({ $0.isNumber }) else {
            return .failure(ToolboxError(message: "First 17 characters must be digits"))
        }
        var sum = 0
        for (index, character) in characters.prefix(17).enumerated() {
            guard let digit = character.wholeNumberValue else {
                return .failure(ToolboxError(message: "Invalid digit"))
            }
            sum += digit * weights[index]
        }
        let expected = checkMap[sum % 11]
        guard String(characters[17]) == expected else {
            return .failure(ToolboxError(message: "Checksum mismatch (expected \(expected))"))
        }
        let birth = String(characters[6..<14])
        let year = Int(birth.prefix(4)) ?? 0
        let month = Int(birth.dropFirst(4).prefix(2)) ?? 0
        let day = Int(birth.dropFirst(6).prefix(2)) ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard year >= 1900, components.isValidDate(in: calendar) else {
            return .failure(ToolboxError(message: "Birth date is invalid"))
        }
        let genderDigit = characters[16].wholeNumberValue ?? 0
        return .success(Info(birthDate: "\(year)-\(String(format: "%02d", month))-\(String(format: "%02d", day))",
                             gender: genderDigit % 2 == 1 ? "Male" : "Female",
                             checkDigit: expected))
    }
}

/// 银行卡号 Luhn 校验 / 计算校验位。
nonisolated enum LuhnCore {
    static func validate(_ raw: String) -> Result<Bool, ToolboxError> {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 2 else { return .failure(ToolboxError(message: "Need at least 2 digits")) }
        guard digits.count == raw.filter({ !$0.isWhitespace && $0 != "-" }).count else {
            return .failure(ToolboxError(message: "Only digits, spaces and dashes are allowed"))
        }
        var sum = 0
        let values = digits.compactMap { $0.wholeNumberValue }
        for (offset, value) in values.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
        }
        return .success(sum % 10 == 0)
    }

    /// 给不带校验位的数字算校验位（返回 0–9）。
    static func checkDigit(for raw: String) -> Result<Int, ToolboxError> {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return .failure(ToolboxError(message: "No digits")) }
        var sum = 0
        let values = digits.compactMap { $0.wholeNumberValue }
        for (offset, value) in values.reversed().enumerated() {
            if offset % 2 == 0 {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
        }
        return .success((10 - sum % 10) % 10)
    }
}

/// 全角/半角转换。
nonisolated enum WidthCore {
    static func toFullWidth(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 32 {
                output.append("\u{3000}")
            } else if scalar.value >= 0x21, scalar.value <= 0x7E {
                if let converted = UnicodeScalar(scalar.value + 0xFEE0) {
                    output.unicodeScalars.append(converted)
                }
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    static func toHalfWidth(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            if scalar.value == 0x3000 {
                output.append(" ")
            } else if scalar.value >= 0xFF01, scalar.value <= 0xFF5E {
                if let converted = UnicodeScalar(scalar.value - 0xFEE0) {
                    output.unicodeScalars.append(converted)
                }
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}

/// 随机字符串 / 随机整数。
nonisolated enum RandomCore {
    static func strings(length: Int, alphabet: String, count: Int = 1) -> [String] {
        let characters = Array(alphabet)
        guard !characters.isEmpty else { return [] }
        var generator = SystemRandomNumberGenerator()
        return (0..<max(1, count)).map { _ in
            String((0..<max(1, length)).map { _ in characters.randomElement(using: &generator)! })
        }
    }

    static func integers(min: Int, max: Int, count: Int, unique: Bool) -> [Int] {
        guard min <= max else { return [] }
        let span = max - min + 1
        var generator = SystemRandomNumberGenerator()
        if unique {
            let limit = Swift.min(span, Swift.max(1, count))
            var pool = Array(min...max)
            pool.shuffle(using: &generator)
            return Array(pool.prefix(limit))
        }
        return (0..<Swift.max(1, count)).map { _ in Int.random(in: min...max, using: &generator) }
    }
}
