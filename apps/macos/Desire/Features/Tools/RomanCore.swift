import Foundation

/// 罗马数字 ↔ 阿拉伯数字（1–3999）——纯逻辑。
nonisolated enum RomanCore {
    private static let pairs: [(value: Int, symbol: String)] = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
        (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]

    static func toRoman(_ value: Int) -> String? {
        guard value >= 1, value <= 3999 else { return nil }
        var remainder = value
        var out = ""
        for pair in pairs {
            while remainder >= pair.value {
                out += pair.symbol
                remainder -= pair.value
            }
        }
        return out
    }

    static func fromRoman(_ text: String) -> Int? {
        var values: [Int] = []
        for character in text.uppercased() {
            guard let pair = pairs.first(where: { $0.symbol == String(character) }) else { return nil }
            values.append(pair.value)
        }
        guard !values.isEmpty else { return nil }
        var total = 0
        for (index, value) in values.enumerated() {
            if index + 1 < values.count, values[index + 1] > value {
                total -= value
            } else {
                total += value
            }
        }
        // 回读校验：MMXXII 之类合法；IIII 这类非法写法拒绝
        guard toRoman(total) == text.uppercased() else { return nil }
        return total
    }
}
