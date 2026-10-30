import CryptoKit
import Foundation

/// 工具箱的摘要算法（CryptoKit；MD5 走 Insecure.MD5）。
nonisolated enum ToolsCrypto {
    enum Algorithm: String, CaseIterable, Sendable {
        case md5
        case sha1
        case sha256
        case sha512

        var title: String {
            switch self {
            case .md5: return "MD5"
            case .sha1: return "SHA-1"
            case .sha256: return "SHA-256"
            case .sha512: return "SHA-512"
            }
        }
    }

    static func hash(_ text: String, algorithm: Algorithm) -> String {
        let data = Data(text.utf8)
        switch algorithm {
        case .md5:
            return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha1:
            return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha256:
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha512:
            return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func hmacSHA256(_ text: String, key: String) -> String {
        let symmetric = SymmetricKey(data: Data(key.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: symmetric)
        return signature.map { String(format: "%02x", $0) }.joined()
    }
}
