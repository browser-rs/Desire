import Foundation

/// ULID（v0.8.33 开发批）：48 位毫秒时间戳 + 80 位随机数，
/// Crockford Base32 共 26 字符，可按字典序排序。纯 Foundation、进 tests/run.sh。
nonisolated enum ULIDCore {

    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 生成（randomness 必须 10 字节）。
    static func generate(at date: Date = Date(), randomness: [UInt8]) -> String? {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970) * 1000)
        return encode(milliseconds: milliseconds, randomness: randomness)
    }

    static func encode(milliseconds: UInt64, randomness: [UInt8]) -> String? {
        guard milliseconds < (1 << 48), randomness.count == 10 else { return nil }
        var output = ""
        for index in 0..<10 {
            let shift = 5 * (9 - index)
            output.append(alphabet[Int((milliseconds >> UInt64(shift)) & 0x1F)])
        }
        // 80 位随机数 → 16 个字符（每次取 5 位，共 80 位）。
        var buffer: UInt64 = 0
        var bits = 0
        for byte in randomness {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int((buffer >> UInt64(bits)) & 0x1F)])
            }
        }
        return output.count == 26 ? output : nil
    }

    static func decode(_ text: String) -> (milliseconds: UInt64, randomness: [UInt8])? {
        let cleaned = Array(text.uppercased().trimmingCharacters(in: .whitespaces))
        guard cleaned.count == 26 else { return nil }
        var milliseconds: UInt64 = 0
        for character in cleaned.prefix(10) {
            guard let value = value(of: character) else { return nil }
            milliseconds = (milliseconds << 5) | UInt64(value)
        }
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for character in cleaned.dropFirst(10) {
            guard let value = value(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        guard bytes.count == 10, milliseconds < (1 << 48) else { return nil }
        return (milliseconds, bytes)
    }

    /// 80 位随机数递增（同一毫秒内的单调性）；溢出回退为全零。
    static func increment(randomness: [UInt8]) -> [UInt8] {
        guard randomness.count == 10 else { return Array(repeating: 0, count: 10) }
        var output = randomness
        for index in stride(from: output.count - 1, through: 0, by: -1) {
            if output[index] == 0xFF {
                output[index] = 0
            } else {
                output[index] += 1
                return output
            }
        }
        return Array(repeating: 0, count: 10)
    }

    private static func value(of character: Character) -> Int? {
        switch character {
        case "0", "O": return 0
        case "1", "I", "L": return 1
        case "U": return nil
        default: return alphabet.firstIndex(of: character)
        }
    }
}
