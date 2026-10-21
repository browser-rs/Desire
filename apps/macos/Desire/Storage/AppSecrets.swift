import Foundation

/// `AppSecretsVault` 的单条目内容（Foundation-only，进纯逻辑单测）。
///
/// - `aiKeys`：AI 档案 Key，按 Keychain account 字符串索引；
/// - `aiChecked`：已迁移/显式删除过的账号——区分"没迁移过"与"确认没有 Key"，
///   否则先建好的 app vault 会把旧 AI Key 误判为已删除；
/// - `sync`：同步的主密钥/access/refresh。
nonisolated struct AppSecrets: Codable {
    var aiKeys: [String: String] = [:]
    var aiChecked: Set<String> = []
    var sync: SyncSecretBundle = .init()

    var isEmpty: Bool { aiKeys.isEmpty && sync.isEmpty }
}
