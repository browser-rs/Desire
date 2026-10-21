import Foundation

/// 同步凭据的**单条目**封装（2026-10-22）。
///
/// 此前 master/access/refresh 是三条独立的 Keychain 条目：adhoc 构建每次换
/// cdhash，读每条都会弹一次授权。把三者合并进一条 `sync-secrets-v1`，新安装
/// 每次升级最多只为首个读取弹一次。`access` 是短命令牌，也一并放进来，避免
/// 同步请求各读一条。
///
/// 旧安装的三条条目保留为迁移来源；`SyncStore.migrateSyncSecrets()` 在用户
/// 显式点击后读一次、写成本条目（不自动读——那正是"每条都弹"的来源）。
nonisolated struct SyncSecretBundle: Codable {
    /// base64 的主密钥（E2E DEK）。
    var master: String?
    var access: String?
    var refresh: String?

    var isEmpty: Bool { master == nil && access == nil && refresh == nil }
}

extension SyncSecretBundle {
    /// Keychain 里的 account 名。改名字 = 旧条目全部变孤儿，别改。
    static let account = "sync-secrets-v1"
}
