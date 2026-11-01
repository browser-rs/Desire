import CryptoKit
import Foundation

/// TOTP（RFC 6238，v0.8.33 开发批）：Base32 密钥 + HMAC-SHA1/256/512，
/// 30/60 秒窗口、6/8 位。密钥只在本机内存里参与计算，不落盘、不日志。
/// 纯 Foundation + CryptoKit、进 tests/run.sh。
nonisolated enum TOTPCore {

    enum Algorithm: String, CaseIterable, Identifiable, Sendable {
        case sha1, sha256, sha512
        var id: String { rawValue }
        var displayName: String { rawValue.uppercased() }
    }

    /// 指定时刻的步数（默认 30 秒）。
    static func counter(for date: Date, period: Int = 30) -> UInt64 {
        let interval = max(1, period)
        let seconds = date.timeIntervalSince1970
        guard seconds > 0 else { return 0 }
        return UInt64(seconds / Double(interval))
    }

    /// 当前窗口剩余秒数（1...period）。
    static func secondsRemaining(for date: Date, period: Int = 30) -> Int {
        let interval = max(1, period)
        let seconds = Int(date.timeIntervalSince1970)
        let remainder = ((seconds % interval) + interval) % interval
        return interval - remainder
    }

    /// Base32 密钥 → 当前验证码；密钥非法/为空返回 nil。
    static func code(secret: String, date: Date = Date(), period: Int = 30,
                     digits: Int = 6, algorithm: Algorithm = .sha1) -> String? {
        guard let key = Base32Core.decode(secret), !key.isEmpty else { return nil }
        return code(key: key, counter: counter(for: date, period: period),
                    digits: digits, algorithm: algorithm)
    }

    /// 指定步数的验证码（RFC 6238 测试向量走这条）。
    static func code(key: Data, counter: UInt64, digits: Int = 6,
                     algorithm: Algorithm = .sha1) -> String? {
        guard !key.isEmpty, [6, 8].contains(digits) else { return nil }
        var message = counter.bigEndian
        let messageData = withUnsafeBytes(of: &message) { Data($0) }
        let hash = Array(hmac(key: key, message: messageData, algorithm: algorithm))
        guard hash.count >= 20 else { return nil }
        let offset = Int(hash[hash.count - 1] & 0x0F)
        guard offset + 4 <= hash.count else { return nil }
        let binary = (UInt32(hash[offset] & 0x7F) << 24)
            | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8)
            | UInt32(hash[offset + 3])
        let modulus: UInt32 = digits == 8 ? 100_000_000 : 1_000_000
        return String(format: "%0\(digits)d", Int(binary % modulus))
    }

    private static func hmac(key: Data, message: Data,
                             algorithm: Algorithm) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        switch algorithm {
        case .sha1:
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message,
                                                               using: symmetricKey))
        case .sha256:
            return Data(HMAC<SHA256>.authenticationCode(for: message,
                                                        using: symmetricKey))
        case .sha512:
            return Data(HMAC<SHA512>.authenticationCode(for: message,
                                                        using: symmetricKey))
        }
    }
}
