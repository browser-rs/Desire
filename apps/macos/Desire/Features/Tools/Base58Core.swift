import Foundation

/// Base58（Bitcoin 字母表，无 0/O/I/l）——纯逻辑。
nonisolated enum Base58Core {
    static let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    static func encode(_ text: String) -> String {
        encode(Data(text.utf8))
    }

    static func encode(_ data: Data) -> String {
        var zeros = 0
        for byte in data {
            if byte == 0 { zeros += 1 } else { break }
        }
        var digits: [UInt8] = []
        for byte in data {
            var carry = Int(byte)
            for index in 0..<digits.count {
                carry += Int(digits[index]) << 8
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let characters = Array(alphabet)
        var out = String(repeating: "1", count: zeros)
        for digit in digits.reversed() {
            out.append(characters[Int(digit)])
        }
        return out
    }

    static func decode(_ raw: String) -> Result<String, ToolboxError> {
        let characters = Array(alphabet)
        var values: [Int] = []
        var zeros = 0
        for character in raw {
            if character == "1", values.isEmpty { zeros += 1; continue }
            guard let index = characters.firstIndex(of: character) else {
                return .failure(ToolboxError(message: "Invalid Base58 character: \(character)"))
            }
            var carry = index
            for position in 0..<values.count {
                carry += values[position] * 58
                values[position] = carry % 256
                carry /= 256
            }
            while carry > 0 {
                values.append(carry % 256)
                carry /= 256
            }
        }
        var data = Data(values.reversed().map(UInt8.init))
        data.insert(contentsOf: Array(repeating: UInt8(0), count: zeros), at: 0)
        guard let string = String(data: data, encoding: .utf8) else {
            return .failure(ToolboxError(message: "Decoded bytes are not UTF-8 text"))
        }
        return .success(string)
    }
}
