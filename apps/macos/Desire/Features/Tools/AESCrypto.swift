import CryptoKit
import Foundation
import Security

/// AES-GCM 文本加解密（口令派生密钥）——纯逻辑，可进 harness。
///
/// 格式：base64(0x01 | salt[16] | nonce[12] | ciphertext+tag)。
/// 密钥派生：PBKDF2-HMAC-SHA256（默认 6 万轮；冷门工具用途，兼顾速度）。
nonisolated enum AESCrypto {
    struct Failure: Error, Equatable, Sendable {
        var message: String
    }

    static let iterations = 60_000
    static let saltLength = 16

    static func encrypt(_ plaintext: String, password: String,
                        iterations: Int = AESCrypto.iterations) -> Result<String, Failure> {
        guard !password.isEmpty else { return .failure(Failure(message: "Passphrase is empty")) }
        var salt = Data(count: saltLength)
        salt.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, buffer.baseAddress!)
        }
        let key = deriveKey(password: password, salt: salt, iterations: iterations)
        do {
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
            var payload = Data([0x01])
            payload.append(salt)
            payload.append(sealed.nonce.withUnsafeBytes { Data($0) })
            payload.append(sealed.ciphertext)
            payload.append(sealed.tag)
            return .success(payload.base64EncodedString())
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
    }

    static func decrypt(_ base64: String, password: String,
                        iterations: Int = AESCrypto.iterations) -> Result<String, Failure> {
        guard !password.isEmpty else { return .failure(Failure(message: "Passphrase is empty")) }
        var text = base64.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = text.count % 4
        if padding > 0 { text += String(repeating: "=", count: 4 - padding) }
        guard let payload = Data(base64Encoded: text), payload.count > 1 + saltLength + 12 + 16,
              payload.first == 0x01 else {
            return .failure(Failure(message: "Not an encrypted payload"))
        }
        let saltStart = payload.startIndex + 1
        let salt = payload[saltStart..<(saltStart + saltLength)]
        let nonceStart = saltStart + saltLength
        let nonceData = payload[nonceStart..<(nonceStart + 12)]
        let cipherStart = nonceStart + 12
        let cipherData = payload[cipherStart...]
        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            return .failure(Failure(message: "Invalid nonce"))
        }
        let key = deriveKey(password: password, salt: Data(salt), iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(cipherData.dropLast(16)),
                                            tag: Data(cipherData.suffix(16)))
            let opened = try AES.GCM.open(box, using: key)
            guard let string = String(data: opened, encoding: .utf8) else {
                return .failure(Failure(message: "Decrypted bytes are not UTF-8 text"))
            }
            return .success(string)
        } catch {
            return .failure(Failure(message: "Wrong passphrase or damaged payload"))
        }
    }

    private static func deriveKey(password: String, salt: Data,
                                  iterations: Int) -> SymmetricKey {
        let key = SymmetricKey(data: Data(password.utf8))
        var firstInput = salt
        firstInput.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: firstInput, using: key))
        var derived = u
        if iterations > 1 {
            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for index in derived.indices {
                    derived[index] ^= u[index]
                }
            }
        }
        return SymmetricKey(data: derived)
    }
}
