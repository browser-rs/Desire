import CryptoKit
import Foundation

/// 与 Mac 端同构的 E2E 加解密：AES-256-GCM，combined(nonce+密文+tag) → base64。
/// 会话密钥只在配对二维码里传输，中继服务器拿不到。
enum RemoteCrypto {
    static func encrypt(text: String, sessionKeyB64: String) -> String? {
        guard let keyData = Data(base64Encoded: sessionKeyB64), keyData.count == 32,
              let plain = text.data(using: .utf8) else { return nil }
        let key = SymmetricKey(data: keyData)
        guard let sealed = try? AES.GCM.seal(plain, using: key).combined else { return nil }
        return sealed.base64EncodedString()
    }

    static func decrypt(payloadB64: String, sessionKeyB64: String) -> String? {
        guard let keyData = Data(base64Encoded: sessionKeyB64), keyData.count == 32,
              let combined = Data(base64Encoded: payloadB64) else { return nil }
        let key = SymmetricKey(data: keyData)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// 内层业务帧：prompt/cancel/sync（手机 → Mac）。
    static func innerFrame(_ dict: [String: String], sessionKeyB64: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return encrypt(text: String(data: data, encoding: .utf8) ?? "", sessionKeyB64: sessionKeyB64)
    }
}
