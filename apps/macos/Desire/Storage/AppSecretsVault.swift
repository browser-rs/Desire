import Foundation

/// 应用级密钥单条目（2026-10-22，v0.8.0）。
///
/// 目标：**一次安装最多一次 Keychain 授权**，而不是每个 AI 档案/同步令牌/
/// 网站密码各弹一次。macOS 的 ACL 按条目授权，唯一可靠的办法是把同类密钥
/// 合并进**一个** item：
///
/// - `aiKeys`：各 AI 档案的 API Key（按 Keychain account 字符串索引）；
/// - `aiChecked`：已迁移/显式删除过的账号。用于区分"没迁移过"和"迁移后
///   确认没有 Key"——否则同步条目先建好 app vault 后，旧 AI Key 会被误判为
///   已删除；
/// - `sync`：同步的主密钥/access/refresh（沿用 `SyncSecretBundle` 结构）。
///
/// `ensureLoaded()` 会读一条 Keychain（可能触发一次授权）；启动路径只在
/// 同步/Agent 真正需要密钥时调用。若 app vault 不存在但上一版的
/// `sync-secrets-v1` 存在，会用后者做种子（只读一条），随后写成 app vault。
/// AI Key 不做批量迁移：首次使用时读那一条、写进 vault（一次授权），
/// 避免为了"合并"把所有旧 key 一次读出来。
@MainActor
final class AppSecretsVault {
    static let shared = AppSecretsVault()

    nonisolated static let account = "app-secrets-v1"
    private let service = KeychainService.defaultService

    private var cache: AppSecrets?
    private var loaded = false
    private var loadFailed = false
    private var vaultExists = false

    var isLoaded: Bool { loaded }
    var hasVault: Bool { vaultExists }
    /// 读取 app vault 失败（用户拒绝/锁屏）时不允许覆盖写，避免丢密钥。
    var isWritable: Bool { !loadFailed }

    private init() {}

    /// 显式加载。只读一条 Keychain；可能触发一次 ACL 授权。
    @discardableResult
    func ensureLoaded() -> AppSecrets {
        if loaded, let cache { return cache }
        loaded = true
        vaultExists = KeychainService.exists(account: Self.account, service: service)
        if vaultExists {
            if let data = KeychainService.read(account: Self.account, service: service,
                                               interactive: false),
               let decoded = try? JSONDecoder().decode(AppSecrets.self, from: data) {
                cache = decoded
                return decoded
            }
            // 条目存在却读不出（拒绝/权限）：标记失败，别拿空结构覆盖。
            loadFailed = true
            let empty = AppSecrets()
            cache = empty
            return empty
        }
        // 没有 app vault：用上一版的同步单条目做种子（只读这一条）。
        var seeded = AppSecrets()
        if let data = KeychainService.read(account: SyncSecretBundle.account, service: service,
                                           interactive: false),
           let sync = try? JSONDecoder().decode(SyncSecretBundle.self, from: data) {
            seeded.sync = sync
        }
        cache = seeded
        if !seeded.sync.isEmpty { save(seeded) }
        return seeded
    }

    // MARK: - AI keys

    /// 不加载、不读盘——启动路径只看内存。
    func cachedAIKey(_ account: String) -> String? {
        cache?.aiKeys[account]
    }

    func isAIChecked(_ account: String) -> Bool {
        cache?.aiChecked.contains(account) ?? false
    }

    @discardableResult
    func setAIKey(_ key: String, for account: String) -> Bool {
        var secrets = ensureLoaded()
        guard isWritable else { return false }
        secrets.aiKeys[account] = key
        secrets.aiChecked.insert(account)
        commit(secrets)
        return true
    }

    @discardableResult
    func removeAIKey(for account: String) -> Bool {
        var secrets = ensureLoaded()
        guard isWritable else { return false }
        secrets.aiKeys.removeValue(forKey: account)
        secrets.aiChecked.insert(account)
        commit(secrets)
        return true
    }

    /// 旧条目不存在时也应记录"查过了"，避免每次回合都去读一条不存在的 item。
    func markAIChecked(_ account: String) {
        guard isWritable else { return }
        var secrets = ensureLoaded()
        secrets.aiChecked.insert(account)
        commit(secrets)
    }

    // MARK: - Sync

    var sync: SyncSecretBundle {
        cache?.sync ?? SyncSecretBundle()
    }

    func setSync(_ sync: SyncSecretBundle) {
        var secrets = ensureLoaded()
        guard isWritable else { return }
        secrets.sync = sync
        commit(secrets)
    }

    func updateSync(_ mutate: (inout SyncSecretBundle) -> Void) {
        var secrets = ensureLoaded()
        guard isWritable else { return }
        mutate(&secrets.sync)
        commit(secrets)
    }

    // MARK: - Persistence

    private func commit(_ secrets: AppSecrets) {
        cache = secrets
        save(secrets)
    }

    private func save(_ secrets: AppSecrets) {
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        KeychainService.write(data, account: Self.account, service: service)
        vaultExists = true
    }
}
