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
    /// 后台加载句柄（启动 preload）。**Keychain 读取绝不能在主线程等授权窗**
    /// ——2026-10-22 实测：新构建启动时 SecurityAgent 弹窗未答，主线程卡在
    /// SecItemCopyMatching，桥/UI 全部无响应。preload 把读放到协作线程池外
    /// 的串行后台任务里，主 actor 只 await 结果，不阻塞。
    private var loadTask: Task<LoadResult, Never>?

    private struct LoadResult: Sendable {
        let secrets: AppSecrets
        let exists: Bool
        let failed: Bool
    }

    var isLoaded: Bool { loaded }
    var isLoading: Bool { loadTask != nil }
    var hasVault: Bool { vaultExists }
    /// 读取 app vault 失败/尚在授权时不允许覆盖写，避免丢密钥。
    var isWritable: Bool { !loadFailed && !isLoading }

    private init() {}

    /// 启动/同步前调用：Keychain 读取在后台任务里，主线程只 await，不阻塞。
    func preload() async {
        if loaded { return }
        if let loadTask {
            _ = await loadTask.value
            return
        }
        let task = Task.detached(priority: .userInitiated) {
            Self.loadFromKeychain()
        }
        loadTask = task
        let result = await task.value
        loadTask = nil
        apply(result)
    }

    /// 显式加载（用户在场路径，如设置页保存 Key）。若后台 preload 正在进行，
    /// 绝不在这里同步阻塞主线程：返回空结构，由调用方按"不可写"处理。
    @discardableResult
    func ensureLoaded() -> AppSecrets {
        if loaded, let cache { return cache }
        if isLoading { return cache ?? AppSecrets() }
        let result = Self.loadFromKeychain()
        apply(result)
        return result.secrets
    }

    private func apply(_ result: LoadResult) {
        cache = result.secrets
        loaded = true
        vaultExists = result.exists
        loadFailed = result.failed
    }

    /// 只读 Keychain；在后台任务里执行，不能访问实例状态。
    private nonisolated static func loadFromKeychain() -> LoadResult {
        let service = KeychainService.defaultService
        let exists = KeychainService.exists(account: Self.account, service: service)
        if exists {
            if let data = KeychainService.read(account: Self.account, service: service,
                                               interactive: false),
               let decoded = try? JSONDecoder().decode(AppSecrets.self, from: data) {
                return LoadResult(secrets: decoded, exists: true, failed: false)
            }
            return LoadResult(secrets: AppSecrets(), exists: true, failed: true)
        }
        // 没有 app vault：用上一版的同步单条目做种子（只读这一条）。
        var seeded = AppSecrets()
        if let data = KeychainService.read(account: SyncSecretBundle.account, service: service,
                                           interactive: false),
           let sync = try? JSONDecoder().decode(SyncSecretBundle.self, from: data) {
            seeded.sync = sync
        }
        if !seeded.sync.isEmpty,
           let data = try? JSONEncoder().encode(seeded) {
            KeychainService.write(data, account: Self.account, service: service)
        }
        return LoadResult(secrets: seeded, exists: false, failed: false)
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
