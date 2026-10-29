import Foundation

/// 统一备份归档（v0.7.28）：版本化 JSON，**按域存编码后的 payload + 计数**。
/// 纯逻辑（Foundation-only，进 harness）——应用内导出/导入与桥走同一格式。
///
/// 刻意不包含：Keychain / API Key / 同步主密钥 / 对话正文（体积与隐私）。
nonisolated struct BackupArchive: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: Date
    var appVersion: String
    /// 域名 → 该域模型的 JSON（外层 JSON 里是 base64）。
    var payloads: [String: Data]
    /// 域名 → 条目数（展示/校验用）。
    var counts: [String: Int]

    enum Domain: String, CaseIterable {
        case settings
        case bookmarks
        case history
        case readingList
        case quickDials
        case agentMemory
        case readerHighlights
        case workflows
        case excerpts          // v0.8.21
        case clipboard         // v0.8.21（24h TTL 条目，含墓碑）

        var title: String {
            switch self {
            case .settings: return String(localized: "Settings")
            case .bookmarks: return String(localized: "Bookmarks")
            case .history: return String(localized: "History")
            case .readingList: return String(localized: "Reading List")
            case .quickDials: return String(localized: "Quick Dials")
            case .agentMemory: return String(localized: "Agent Memory")
            case .readerHighlights: return String(localized: "Reader Highlights")
            case .workflows: return String(localized: "Web Workflows")
            case .excerpts: return String(localized: "Excerpts")
            case .clipboard: return String(localized: "Clipboard History")
            }
        }
    }

    var isSupported: Bool { version >= 1 && version <= Self.currentVersion }

    func decoded<T: Decodable>(_ type: T.Type, domain: Domain) -> T? {
        guard let data = payloads[domain.rawValue] else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encodePayload<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func encode(_ archive: BackupArchive) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(archive)
    }

    static func decode(_ data: Data) -> BackupArchive? {
        try? JSONDecoder().decode(BackupArchive.self, from: data)
    }
}

/// 设置值（备份用）：与同步域的 SettingsSyncValue 一一对应，单独定义以保持
/// 本文件零依赖（服务层负责转换）。
nonisolated enum BackupSettingValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
}

/// v2 加密信封（v0.7.29）：口令 → PBKDF2-SHA256 → AES-GCM 包裹**整个**明文
/// 归档。文件头只留 KDF 参数与密文，磁盘/传输上看不到书签/历史/记忆内容。
nonisolated struct EncryptedBackupEnvelope: Codable, Equatable {
    static let format = "desire-backup-encrypted"
    static let currentVersion = 2
    static let kdfName = "pbkdf2-sha256"

    var format: String
    var version: Int
    var kdf: String
    var iterations: Int
    /// base64(16B random salt)
    var salt: String
    /// base64(AES-GCM combined: nonce+ciphertext+tag)
    var ct: String
    var exportedAt: Date
    var appVersion: String

    var isSupported: Bool {
        format == Self.format
            && version >= 2 && version <= Self.currentVersion
            && kdf == Self.kdfName
            && iterations > 0
            && !salt.isEmpty && !ct.isEmpty
    }

    static func encode(_ envelope: EncryptedBackupEnvelope) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(envelope)
    }

    static func decode(_ data: Data) -> EncryptedBackupEnvelope? {
        try? JSONDecoder().decode(EncryptedBackupEnvelope.self, from: data)
    }
}
