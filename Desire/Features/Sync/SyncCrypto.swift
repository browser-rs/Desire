import CryptoKit
import Foundation

/// E2E 加密核心。威胁模型:服务器数据库被拖库/管理员不可信——
/// 服务器只存「不透明 client_id(HMAC)+ AES-GCM 密文 + 时间戳元数据」,
/// 主密钥(256 位)只在客户端 Keychain,永不上传;新设备靠用户手动导入 base64。
///
/// 派生:每域独立密钥(HKDF-SHA256,info 域分离),载荷键与 client_id 键分开——
/// client_id 用 HMAC(确定性,服务器保唯一性/等值匹配,读不出真实 id)。
nonisolated enum SyncCrypto {

    enum CryptoError: LocalizedError {
        case invalidKeyFormat
        case authenticationFailed
        case cryptoFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidKeyFormat: String(localized: "Invalid sync key format")
            case .authenticationFailed: String(localized: "Sync key does not match this data")
            case .cryptoFailure(let message): String(localized: "Sync encryption failed: \(message)")
            }
        }
    }

    static let envelopeVersion = 1
    private static let fingerprintLength = 16 // hex 字符数(展示用)

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    // MARK: - 主密钥(base64 对外;32 字节)

    public static func generateMasterKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    public static func isValidMasterKeyBase64(_ text: String) -> Bool {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        return data.count == 32
    }

    private static func masterKey(_ base64: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespaces)),
              data.count == 32 else {
            throw CryptoError.invalidKeyFormat
        }
        return SymmetricKey(data: data)
    }

    /// 密钥指纹:hex(HMAC(主密钥, "fingerprint")) 前 16 位,设置页展示用。
    public static func fingerprint(masterKeyBase64: String) throws -> String {
        String(try keyCheckHex(masterKeyBase64: masterKeyBase64).prefix(fingerprintLength))
    }

    /// 服务端存储/校验用的全量 64 位 hex(与 fingerprint 同源)。
    public static func keyCheckHex(masterKeyBase64: String) throws -> String {
        let key = try masterKey(masterKeyBase64)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Data("desire-sync".utf8),
            info: Data("fingerprint".utf8),
            outputByteCount: 32
        )
        let tag = HMAC<SHA256>.authenticationCode(for: Data("fingerprint".utf8), using: derived)
        return Data(tag).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 域派生密钥

    private static func domainKey(
        _ masterKeyBase64: String, domain: SyncDomain, purpose: String
    ) throws -> SymmetricKey {
        let master = try masterKey(masterKeyBase64)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data("desire-sync".utf8),
            info: Data("desire-sync/v1/\(domain.rawValue)/\(purpose)".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - 载荷加密(AES-256-GCM,combined = nonce+ct+tag)

    public static func encrypt<T: Encodable>(
        _ value: T, domain: SyncDomain, masterKeyBase64: String
    ) throws -> SyncEncryptedPayload {
        let key = try domainKey(masterKeyBase64, domain: domain, purpose: "payload")
        let plaintext: Data
        do {
            plaintext = try SyncJSON.makeEncoder().encode(value)
        } catch {
            throw CryptoError.cryptoFailure("payload encode: \(error.localizedDescription)")
        }
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw CryptoError.cryptoFailure("AES-GCM seal: \(error.localizedDescription)")
        }
        guard let combined = sealed.combined else {
            throw CryptoError.cryptoFailure("AES-GCM seal returned no combined representation")
        }
        return SyncEncryptedPayload(
            v: envelopeVersion,
            ct: base64URL(combined)
        )
    }

    public static func decrypt<T: Decodable>(
        _ envelope: SyncEncryptedPayload, domain: SyncDomain,
        masterKeyBase64: String, as type: T.Type
    ) throws -> T {
        guard envelope.v == envelopeVersion else {
            throw CryptoError.cryptoFailure("unknown envelope version \(envelope.v)")
        }
        guard let combined = base64URLDecode(envelope.ct) else {
            throw CryptoError.invalidKeyFormat
        }
        let key = try domainKey(masterKeyBase64, domain: domain, purpose: "payload")
        let sealed: AES.GCM.SealedBox
        let plaintext: Data
        do {
            sealed = try AES.GCM.SealedBox(combined: combined)
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            // 认证失败 = 密钥不对或密文被篡改
            throw CryptoError.authenticationFailed
        }
        return try SyncJSON.makeDecoder().decode(T.self, from: plaintext)
    }

    // MARK: - client_id(确定性 HMAC;服务器保唯一性,读不出真实 id)

    public static func hmacClientID(
        _ realID: String, domain: SyncDomain, masterKeyBase64: String
    ) -> String {
        let key = (try? domainKey(masterKeyBase64, domain: domain, purpose: "client-id"))
            ?? SymmetricKey(size: .bits256)
        let tag = HMAC<SHA256>.authenticationCode(for: Data(realID.utf8), using: key)
        return base64URL(Data(tag))
    }
}
