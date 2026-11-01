import Foundation

/// IEEE 754 浮点位模式（v0.8.33 开发批）：float32/64 ↔ 十进制/十六进制，
/// 含符号/指数/尾数与大小端。纯 Foundation、进 tests/run.sh。
nonisolated enum FloatBitsCore {

    struct Fields: Equatable, Sendable {
        var negative: Bool
        var exponent: Int
        var mantissa: UInt64
        var bias: Int
        var isNaN: Bool
        var isInfinite: Bool
    }

    /// 十进制文本 → Double（支持 NaN/Inf/-Inf）。
    static func parseDecimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch trimmed {
        case "nan", "+nan", "-nan": return .nan
        case "inf", "+inf", "infinity", "+infinity": return .infinity
        case "-inf", "-infinity": return -.infinity
        default: return Double(trimmed)
        }
    }

    static func float32Bits(_ value: Double) -> UInt32 {
        Float(value).bitPattern
    }

    static func float64Bits(_ value: Double) -> UInt64 {
        value.bitPattern
    }

    static func float32(fromBits bits: UInt32) -> Double {
        Double(Float(bitPattern: bits))
    }

    static func float64(fromBits bits: UInt64) -> Double {
        Double(bitPattern: bits)
    }

    /// `0x3f800000` / `3f800000` → (位模式, 宽度)。
    static func parseHex(_ text: String, width: Int) -> UInt64? {
        var cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
        if cleaned.hasPrefix("0x") { cleaned.removeFirst(2) }
        cleaned = cleaned.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, width == 32 || width == 64 else { return nil }
        guard cleaned.count <= (width == 32 ? 8 : 16) else { return nil }
        guard let value = UInt64(cleaned, radix: 16) else { return nil }
        if width == 32 { return value <= UInt64(UInt32.max) ? value : nil }
        return value
    }

    static func hex(_ bits: UInt64, width: Int) -> String {
        let digits = width == 32 ? 8 : 16
        return "0x" + String(format: "%0\(digits)llx", bits)
    }

    static func littleEndianBits(_ bits: UInt64, width: Int) -> UInt64 {
        if width == 32 {
            let value = UInt32(truncatingIfNeeded: bits)
            return UInt64(value.byteSwapped)
        }
        return bits.byteSwapped
    }

    static func decompose32(_ bits: UInt32) -> Fields {
        let negative = bits & 0x8000_0000 != 0
        let exponentBits = Int((bits >> 23) & 0xFF)
        let mantissa = UInt64(bits & 0x7F_FFFF)
        return Fields(negative: negative, exponent: exponentBits, mantissa: mantissa,
                      bias: 127, isNaN: exponentBits == 0xFF && mantissa != 0,
                      isInfinite: exponentBits == 0xFF && mantissa == 0)
    }

    static func decompose64(_ bits: UInt64) -> Fields {
        let negative = bits & 0x8000_0000_0000_0000 != 0
        let exponentBits = Int((bits >> 52) & 0x7FF)
        let mantissa = bits & 0x000F_FFFF_FFFF_FFFF
        return Fields(negative: negative, exponent: exponentBits, mantissa: mantissa,
                      bias: 1023, isNaN: exponentBits == 0x7FF && mantissa != 0,
                      isInfinite: exponentBits == 0x7FF && mantissa == 0)
    }

    /// 有效指数（0/次正规数返回 nil）。
    static func unbiasedExponent(_ fields: Fields) -> Int? {
        guard fields.exponent != 0, !fields.isNaN, !fields.isInfinite else { return nil }
        return fields.exponent - fields.bias
    }
}
