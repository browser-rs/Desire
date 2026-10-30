import Foundation

/// Excel 列号 ↔ 序号（A=1, Z=26, AA=27, ZZ=702）——纯逻辑。
nonisolated enum ExcelColumnCore {
    static func fromLetters(_ letters: String) -> Int? {
        let upper = letters.uppercased()
        guard !upper.isEmpty, upper.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        var value = 0
        for character in upper {
            value = value * 26 + (Int(character.asciiValue!) - 64)
        }
        return value
    }

    static func toLetters(_ number: Int) -> String? {
        guard number >= 1 else { return nil }
        var value = number
        var out = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + remainder))) + out
            value = (value - 1) / 26
        }
        return out
    }
}
