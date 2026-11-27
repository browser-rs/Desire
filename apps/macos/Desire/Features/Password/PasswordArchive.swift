import CommonCrypto
import CryptoKit
import Foundation
import Security

/// 密码库加密导出（v0.8.82）：口令派生的 AES-GCM 包，替代默认明文 CSV。
///
/// 文件是 JSON 信封（格式/版本/KDF/迭代次数/盐/密文），密文里是条目数组。
/// 纯逻辑（Foundation + CryptoKit + CommonCrypto），harness 可做 round-trip
/// 与错口令测试；Keychain 的读取仍由 `PasswordStore` 在显式导出路径完成。
nonisolated enum PasswordArchive {
    static let format = "desire-passwords"
    static let version = 1
    static let defaultIterations: UInt32 = 600_000
    static let minPasswordLength = 8

    struct Entry: Codable, Equatable {
        var domain: String
        var username: String
        var password: String
        var createdAt: Date?
    }

    struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: UInt32
        var salt: String
        var ciphertext: String
    }

    enum ArchiveError: LocalizedError {
        case emptyPassword
        case weakPassword
        case wrongPasswordOrCorrupt
        case unsupportedFormat
        case missingSecret

        var errorDescription: String? {
            switch self {
            case .emptyPassword: String(localized: "Enter a password for the archive.")
            case .weakPassword: String(localized: "Archive password must be at least 8 characters.")
            case .wrongPasswordOrCorrupt: String(localized: "Wrong password, or the archive is damaged.")
            case .unsupportedFormat: String(localized: "This is not a Desire password archive.")
            case .missingSecret: String(localized: "Some saved passwords could not be read from the keychain; export was cancelled.")
            }
        }
    }

    static func encrypt(entries: [Entry], password: String,
                        iterations: UInt32 = defaultIterations) throws -> Data {
        guard !password.isEmpty else { throw ArchiveError.emptyPassword }
        guard password.count >= minPasswordLength else { throw ArchiveError.weakPassword }
        let salt = randomSalt()
        let key = try deriveKey(password: password, salt: salt,
                                iterations: iterations)
        let payload = try JSONEncoder().encode(entries)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else {
            throw ArchiveError.wrongPasswordOrCorrupt
        }
        let envelope = Envelope(format: format, version: version,
                                kdf: "pbkdf2-sha256",
                                iterations: iterations,
                                salt: salt.base64EncodedString(),
                                ciphertext: combined.base64EncodedString())
        return try JSONEncoder().encode(envelope)
    }

    static func decrypt(data: Data, password: String) throws -> [Entry] {
        guard !password.isEmpty else { throw ArchiveError.emptyPassword }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == format, envelope.version == version,
              envelope.kdf == "pbkdf2-sha256",
              let salt = Data(base64Encoded: envelope.salt),
              let ciphertext = Data(base64Encoded: envelope.ciphertext) else {
            throw ArchiveError.unsupportedFormat
        }
        let key = try deriveKey(password: password, salt: salt,
                                iterations: envelope.iterations)
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            let payload = try AES.GCM.open(sealed, using: key)
            return try JSONDecoder().decode([Entry].self, from: payload)
        } catch {
            throw ArchiveError.wrongPasswordOrCorrupt
        }
    }

    // MARK: - KDF

    static func randomSalt() -> Data {
        var bytes = Data(repeating: 0, count: 16)
        _ = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        return bytes
    }

    static func deriveKey(password: String, salt: Data,
                          iterations: UInt32) throws -> SymmetricKey {
        var derived = Data(repeating: 0, count: 32)
        var passwordBytes = Array(password.utf8CString)
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    &passwordBytes, passwordBytes.count - 1,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    32)
            }
        }
        guard status == kCCSuccess else {
            throw ArchiveError.wrongPasswordOrCorrupt
        }
        return SymmetricKey(data: derived)
    }
}
