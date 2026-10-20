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

        var title: String {
            switch self {
            case .settings: return String(localized: "Settings")
            case .bookmarks: return String(localized: "Bookmarks")
            case .history: return String(localized: "History")
            case .readingList: return String(localized: "Reading List")
            case .quickDials: return String(localized: "Quick Dials")
            case .agentMemory: return String(localized: "Agent Memory")
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
