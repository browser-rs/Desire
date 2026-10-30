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
        hash(Data(text.utf8), algorithm: algorithm)
    }

    static func hash(_ data: Data, algorithm: Algorithm) -> String {
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

    /// 文件摘要（分块读取，大文件不整读进内存）。
    static func hashFile(_ url: URL, algorithm: Algorithm) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunkSize = 1 << 20
        switch algorithm {
        case .md5:
            var hasher = Insecure.MD5()
            while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize())
        case .sha1:
            var hasher = Insecure.SHA1()
            while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize())
        case .sha256:
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize())
        case .sha512:
            var hasher = SHA512()
            while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize())
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
