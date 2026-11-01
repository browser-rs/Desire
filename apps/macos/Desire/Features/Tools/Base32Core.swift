import Foundation

/// Base32（RFC 4648，v0.8.33 开发批）：TOTP 密钥与通用文本编码。
/// 纯 Foundation、进 tests/run.sh。
nonisolated enum Base32Core {

    static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// 标准 Base32；padding 默认补到 8 的倍数。
    static func encode(_ data: Data, padding: Bool = true) -> String {
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            output.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        if padding {
            while output.count % 8 != 0 { output.append("=") }
        }
        return output
    }

    /// 解码：忽略空白与连字符，大小写不敏感，padding 可有可无；
    /// 非法字符或非法长度返回 nil。
    static func decode(_ text: String) -> Data? {
        var characters = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        while characters.last == "=" { characters.removeLast() }
        guard !characters.isEmpty else { return Data() }
        // 合法 Base32 长度余数只可能是 0/2/4/5/7。
        guard [0, 2, 4, 5, 7].contains(characters.count % 8) else { return nil }
        var output = Data()
        var buffer = 0
        var bits = 0
        for character in characters {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return output
    }
}
