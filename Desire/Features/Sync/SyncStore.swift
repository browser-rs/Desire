import Combine
import Foundation
import LocalAuthentication
import Security

/// 云同步会话与编排（Store 层）：登录态（令牌存 Keychain）、每域拉取游标、
/// 立即/定时同步。策略 = 每周期"全量 push + 游标增量 pull"，LWW 仲裁在服务端。
///
/// **E2E 加密**：主密钥（256 位）只在客户端 Keychain，永不上传；每个域用
/// HKDF 派生独立密钥做 AES-256-GCM 载荷加密，client_id 用独立派生密钥做
/// HMAC（服务器只见不透明标签）。服务器另有密钥指纹（HMAC 的 hex）用于
/// 新设备导入校验。见 SyncCrypto。
///
/// Keychain 读全部 `interactive: false`（LAContext interactionNotAllowed）——
/// 启动/回合中路径禁止触发隐窗授权（v0.3.14 教训，见 AGENTS）。
@MainActor
final class SyncStore: ObservableObject {

    enum AuthState: Equatable {
        case signedOut
        case signedIn(username: String)
    }

    @Published private(set) var authState: AuthState = .signedOut
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    /// 最近一次同步/登录失败的展示文本；成功后清空。
    @Published private(set) var lastError: String?
    /// 同步服务器地址（设置页/桥可改，立即生效）。
    @Published private(set) var serverBaseURL: String
    /// 用户选择的同步类目（缺省全开）。关闭 = 跳过该域 push/pull；
    /// 游标保留，重新打开后自动补齐关闭期间的增量；服务端数据不删。
    @Published private(set) var enabledDomains: [SyncDomain: Bool] = [:]
    /// E2E 主密钥是否已在 Keychain。没有密钥时同步被阻止（无法加解密）。
    @Published private(set) var hasSyncKey = false
    /// 密钥指纹（16 位 hex），设置页展示用于跨设备核对。
    @Published private(set) var syncKeyFingerprint: String?

    static let defaultServerBaseURL = "http://127.0.0.1:18090"

    private let bookmarkStore: BookmarkStore
    private let quickDialStore: QuickDialStore
    private let readingListStore: ReadingListStore
    private let shortcutStore: KeyboardShortcutStore
    private let settings: Settings
    private var syncTimer: Timer?
    private let defaults = UserDefaults.standard

    // UserDefaults keys
    private let usernameKey = "sync.username"
    private let serverKey = "sync.serverBaseURL"
    private let deviceIDKey = "sync.deviceID"
    private let lastSyncKey = "sync.lastSyncAt"
    // 设置 KV 域的 LWW 戳与"上次已知值"快照（本地变更靠 diff 检测）
    private let settingsStampsKey = "sync.settings.stamps"
    private let settingsSnapshotKey = "sync.settings.snapshot"

    // Keychain（service = bundle id）
    private let keychainService = "me.siwi.Desire"
    private let accessAccount = "sync-access-token"
    private let refreshAccount = "sync-refresh-token"
    private let masterKeyAccount = "sync-master-key"

    /// 定时同步间隔（5 分钟；各域量小，全量 push 无压力）。
    private let syncInterval: TimeInterval = 300

    init(
        bookmarkStore: BookmarkStore,
        quickDialStore: QuickDialStore,
        readingListStore: ReadingListStore,
        shortcutStore: KeyboardShortcutStore,
        settings: Settings
    ) {
        self.bookmarkStore = bookmarkStore
        self.quickDialStore = quickDialStore
        self.readingListStore = readingListStore
        self.shortcutStore = shortcutStore
        self.settings = settings
        let storedServer = defaults.string(forKey: serverKey) ?? ""
        serverBaseURL = storedServer.isEmpty ? Self.defaultServerBaseURL : storedServer
        for domain in SyncDomain.allCases {
            enabledDomains[domain] = defaults.object(forKey: enabledKey(domain)) as? Bool ?? true
        }
        if let data = keychainReadData(masterKeyAccount) {
            hasSyncKey = true
            syncKeyFingerprint = try? SyncCrypto.fingerprint(masterKeyBase64: data.base64EncodedString())
        }
        if let username = defaults.string(forKey: usernameKey),
           keychainReadData(accessAccount) != nil || keychainReadData(refreshAccount) != nil {
            authState = .signedIn(username: username)
        }
        lastSyncAt = defaults.object(forKey: lastSyncKey) as? Date
    }

    func setServerBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: serverKey)
        serverBaseURL = trimmed
    }

    // MARK: - 类目开关

    private func enabledKey(_ domain: SyncDomain) -> String {
        "sync.enabled.\(domain.rawValue)"
    }

    func isEnabled(_ domain: SyncDomain) -> Bool {
        enabledDomains[domain] ?? true
    }

    func setEnabled(_ domain: SyncDomain, _ enabled: Bool) {
        enabledDomains[domain] = enabled
        defaults.set(enabled, forKey: enabledKey(domain))
    }

    // MARK: - E2E 主密钥

    private var masterKeyBase64: String? {
        keychainReadData(masterKeyAccount)?.base64EncodedString()
    }

    /// 生成新主密钥,返回 base64（仅此一次完整展示,用户自行备份）。
    /// 上报指纹走 `uploadKeyCheck()`。
    func generateSyncKey() throws -> String {
        let key = SyncCrypto.generateMasterKey()
        try storeSyncKey(key)
        return key
    }

    /// 导入既有密钥（新设备/换机）。
    func importSyncKey(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SyncCrypto.isValidMasterKeyBase64(trimmed) else {
            throw SyncCrypto.CryptoError.invalidKeyFormat
        }
        try storeSyncKey(trimmed)
    }

    /// 上报/校验指纹:服务器无指纹 → 登记本机;不一致 → 抛错(拿错密钥)。
    func uploadKeyCheck() async throws {
        guard let master = masterKeyBase64 else {
            throw SyncCrypto.CryptoError.invalidKeyFormat
        }
        let check = try SyncCrypto.keyCheckHex(masterKeyBase64: master)
        let existing: KeyCheckResp = try await SyncAPIClient.keyCheck(
            baseURL: serverBaseURL, accessToken: validAccessToken()
        )
        switch existing.check {
        case nil:
            try await SyncAPIClient.setKeyCheck(
                baseURL: serverBaseURL, fingerprint: check,
                accessToken: validAccessToken()
            )
        case .some(let stored) where stored == check:
            break
        case .some:
            throw SyncCrypto.CryptoError.authenticationFailed
        }
    }

    private func storeSyncKey(_ base64: String) throws {
        guard let data = Data(base64Encoded: base64) else {
            throw SyncCrypto.CryptoError.invalidKeyFormat
        }
        keychainWrite(data, account: masterKeyAccount)
        hasSyncKey = true
        syncKeyFingerprint = try SyncCrypto.fingerprint(masterKeyBase64: base64)
    }

    /// 导出主密钥（设置页"复制到新设备"用）。
    func revealSyncKey() -> String? {
        masterKeyBase64
    }

    // MARK: - 启动后的首次同步 + 定时器

    func startAutoSync() {
        if syncTimer == nil {
            syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.syncNow()
                }
            }
        }
        guard case .signedIn = authState, hasSyncKey else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await self.syncNow()
        }
    }

    // MARK: - 登录 / 注册 / 退出

    func login(username: String, password: String) async throws {
        try await authenticate(username: username, password: password, register: false)
    }

    func register(username: String, password: String) async throws {
        try await authenticate(username: username, password: password, register: true)
    }

    private func authenticate(username: String, password: String, register: Bool) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        let body = SyncAuthBody(
            username: trimmed,
            password: password,
            nickname: nil,
            device: deviceBody()
        )
        let pair: SyncTokenPair
        if register {
            pair = try await SyncAPIClient.register(baseURL: serverBaseURL, body: body)
        } else {
            pair = try await SyncAPIClient.login(baseURL: serverBaseURL, body: body)
        }
        storeTokens(pair)
        defaults.set(trimmed, forKey: usernameKey)
        authState = .signedIn(username: trimmed)
        lastError = nil
        await syncNow()
    }

    func logout() {
        if let refresh = keychainReadString(refreshAccount) {
            let base = serverBaseURL
            Task.detached {
                _ = try? await SyncAPIClient.logout(baseURL: base, refreshToken: refresh)
            }
        }
        keychainDelete(accessAccount)
        keychainDelete(refreshAccount)
        defaults.removeObject(forKey: usernameKey)
        clearSyncState()
        authState = .signedOut
        lastError = nil
    }

    /// 清空账号相关的本地同步状态。游标是**按账号语义**存的（每设备每域的
    /// 拉取位置）——换账号登录若沿用旧账号游标，旧游标之后的增量对新账号
    /// 永久丢失。清掉后重新登录走全量 pull，即"以本机现状 + 服务端全量重建"。
    /// settings 的戳/快照同理清空：新账号首轮 sync 会以本机当前值全量上推。
    /// **主密钥保留**（在 Keychain,属设备而非账号）。
    private func clearSyncState() {
        for domain in SyncDomain.allCases {
            defaults.removeObject(forKey: cursorKey(domain))
        }
        defaults.removeObject(forKey: settingsStampsKey)
        defaults.removeObject(forKey: settingsSnapshotKey)
    }

    /// 修改密码（登录态）。成功后现有令牌仍有效，无需重新登录。
    func changePassword(current: String, new: String) async throws {
        guard case .signedIn = authState else {
            throw SyncAPIError.unauthorized
        }
        let trimmedNew = new.trimmingCharacters(in: .whitespaces)
        guard trimmedNew.count >= 6, trimmedNew.count <= 72 else {
            throw SyncAPIError.server(String(localized: "Password must be 6-72 characters"))
        }
        try await SyncAPIClient.changePassword(
            baseURL: serverBaseURL,
            accessToken: validAccessToken(),
            body: SetPasswordReq(oldPassword: current, newPassword: trimmedNew)
        )
    }

    // MARK: - 同步

    /// 各域 push + pull。已登录、有密钥且空闲才执行；401 时刷新令牌并整体重试一次。
    func syncNow() async {
        guard case .signedIn = authState, !isSyncing else { return }
        guard hasSyncKey else {
            lastError = String(localized: "Set a sync key first — sync stays local until then.")
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await runSyncCycle()
            lastError = nil
        } catch SyncAPIError.unauthorized {
            // access 过期：强制刷新后整体重试一次
            keychainDelete(accessAccount)
            do {
                _ = try await validAccessToken()
                try await runSyncCycle()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func runSyncCycle() async throws {
        let token = try await validAccessToken()
        try await uploadKeyCheck() // 指纹不一致在此抛错,防拿错密钥覆盖旧密文
        guard let master = masterKeyBase64 else {
            throw SyncCrypto.CryptoError.invalidKeyFormat
        }
        if isEnabled(.bookmarks) {
            try await runDomainSync(.bookmarks, token: token, master: master,
                                    collectPush: collectBookmarks,
                                    applyRemote: applyBookmarks,
                                    clearApplied: clearBookmarksPending)
        }
        if isEnabled(.quickDials) {
            try await runDomainSync(.quickDials, token: token, master: master,
                                    collectPush: collectQuickDials,
                                    applyRemote: applyQuickDials,
                                    clearApplied: clearQuickDialsPending)
        }
        if isEnabled(.readingList) {
            try await runDomainSync(.readingList, token: token, master: master,
                                    collectPush: collectReadingList,
                                    applyRemote: applyReadingList,
                                    clearApplied: clearReadingListPending)
        }
        if isEnabled(.keyboardShortcuts) {
            try await runDomainSync(.keyboardShortcuts, token: token, master: master,
                                    collectPush: collectShortcuts,
                                    applyRemote: applyShortcuts,
                                    clearApplied: { _, _ in })
        }
        if isEnabled(.settings) {
            try await runDomainSync(.settings, token: token, master: master,
                                    collectPush: collectSettings,
                                    applyRemote: applySettings,
                                    clearApplied: { _, _ in })
        }
        lastSyncAt = Date()
        defaults.set(lastSyncAt, forKey: lastSyncKey)
    }

    /// 单域骨架:全量 push → conflict 胜者落地 → 清已裁决的待删 →
    /// 游标增量 pull → 合并回写 → 游标推进到末条的 (updated_at, id)。
    private func runDomainSync(
        _ domain: SyncDomain,
        token: String,
        master: String,
        collectPush: (String) -> [SyncWireItem<SyncEncryptedPayload>],
        applyRemote: ([SyncWireItem<SyncEncryptedPayload>], String) -> Void,
        clearApplied: (Set<String>, String) -> Void
    ) async throws {
        let base = serverBaseURL
        let results = try await SyncAPIClient.push(
            baseURL: base, domain: domain.rawValue, items: collectPush(master), accessToken: token
        )
        let winners = results.compactMap { $0.status == "conflict" ? $0.item : nil }
        if !winners.isEmpty { applyRemote(winners, master) }
        // applied 与 conflict 都代表"服务端已权威裁决":applied 是本机赢了,
        // conflict 是服务端赢了(胜者已落地)。两种情况下待删清单里的旧 tombstone
        // 都该清掉——否则输掉 LWW 的删除会每周期重推一遍,永远 conflict。
        clearApplied(Set(results.map(\.clientId)), master)

        // pull 增量。游标是复合的 "updated_at|id"——仅凭时间戳时,同刻行恰跨
        // 分页边界会被 `> since` 永久跳过(静默丢失)。
        let cursor = defaults.string(forKey: cursorKey(domain))
        var since: String?
        var sinceID: Int64?
        if let cursor, !cursor.isEmpty {
            let parts = cursor.split(separator: "|", maxSplits: 1).map(String.init)
            since = parts.first
            sinceID = parts.count > 1 ? Int64(parts[1]) : nil
        }
        let response: SyncPullResponse<SyncEncryptedPayload> = try await SyncAPIClient.pull(
            baseURL: base, domain: domain.rawValue,
            since: since, sinceID: sinceID, accessToken: token
        )
        if !response.items.isEmpty {
            applyRemote(response.items, master)
            if let last = response.items.last {
                defaults.set("\(last.updatedAt ?? "")|\(last.id ?? 0)", forKey: cursorKey(domain))
            }
        }
    }

    // MARK: - 各域 adapter(加解密边界;合并逻辑在 SyncMerge,纯逻辑可测)

    private func encryptedTombstone(
        domain: SyncDomain, realID: String, clientUpdatedAt: Date, master: String
    ) -> SyncWireItem<SyncEncryptedPayload> {
        SyncWireItem(
            clientId: SyncCrypto.hmacClientID(realID, domain: domain, masterKeyBase64: master),
            clientUpdatedAt: clientUpdatedAt,
            deleted: true,
            payload: nil,
            updatedAt: nil
        )
    }

    private func collectBookmarks(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        var items = BookmarkSync.flatten(bookmarkStore.bookmarks).map { entry in
            encryptedWire(
                domain: .bookmarks, realID: entry.id.uuidString,
                clientUpdatedAt: entry.updatedAt, deleted: false, payload: entry.payload,
                master: master)
        }
        for (id, deletedAt) in bookmarkStore.pendingDeletions {
            items.append(encryptedTombstone(
                domain: .bookmarks, realID: id.uuidString,
                clientUpdatedAt: deletedAt, master: master))
        }
        return items
    }

    private func applyBookmarks(_ items: [SyncWireItem<SyncEncryptedPayload>], master: String) {
        let decrypted = decryptItems(items, domain: .bookmarks, master: master, as: BookmarkSyncPayload.self) { item, payload in
            SyncWireItem<BookmarkSyncPayload>(
                clientId: payload.id.uuidString,
                clientUpdatedAt: item.clientUpdatedAt,
                deleted: item.deleted,
                payload: payload,
                updatedAt: item.updatedAt
            )
        }
        bookmarkStore.replaceForSync(
            BookmarkSync.merge(base: bookmarkStore.bookmarks, remote: decrypted)
        )
    }

    private func clearBookmarksPending(_ serverIDs: Set<String>, master: String) {
        let real = bookmarkStore.pendingDeletions.keys.filter {
            serverIDs.contains(SyncCrypto.hmacClientID($0.uuidString, domain: .bookmarks, masterKeyBase64: master))
        }
        bookmarkStore.clearPendingDeletions(Set(real.map(\.uuidString)))
    }

    private func collectQuickDials(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        var items = quickDialStore.dials.map {
            encryptedWire(domain: .quickDials, realID: $0.id.uuidString,
                          clientUpdatedAt: $0.updatedAt, deleted: false,
                          payload: QuickDialSync.payload($0), master: master)
        }
        for (id, deletedAt) in quickDialStore.pendingDeletions {
            items.append(encryptedTombstone(
                domain: .quickDials, realID: id.uuidString,
                clientUpdatedAt: deletedAt, master: master))
        }
        return items
    }

    private func applyQuickDials(_ items: [SyncWireItem<SyncEncryptedPayload>], master: String) {
        let decrypted = decryptItems(items, domain: .quickDials, master: master, as: QuickDialSyncPayload.self) { item, payload in
            SyncWireItem<QuickDialSyncPayload>(
                clientId: payload.id.uuidString,
                clientUpdatedAt: item.clientUpdatedAt,
                deleted: item.deleted,
                payload: payload,
                updatedAt: item.updatedAt
            )
        }
        quickDialStore.replaceForSync(
            QuickDialSync.merge(base: quickDialStore.dials, remote: decrypted)
        )
    }

    private func clearQuickDialsPending(_ serverIDs: Set<String>, master: String) {
        let real = quickDialStore.pendingDeletions.keys.filter {
            serverIDs.contains(SyncCrypto.hmacClientID($0.uuidString, domain: .quickDials, masterKeyBase64: master))
        }
        quickDialStore.clearPendingDeletions(Set(real.map(\.uuidString)))
    }

    private func collectReadingList(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        var items = readingListStore.items.map {
            encryptedWire(domain: .readingList, realID: $0.id.uuidString,
                          clientUpdatedAt: $0.updatedAt, deleted: false,
                          payload: ReadingListSync.payload($0), master: master)
        }
        for (id, deletedAt) in readingListStore.pendingDeletions {
            items.append(encryptedTombstone(
                domain: .readingList, realID: id.uuidString,
                clientUpdatedAt: deletedAt, master: master))
        }
        return items
    }

    private func applyReadingList(_ items: [SyncWireItem<SyncEncryptedPayload>], master: String) {
        let decrypted = decryptItems(items, domain: .readingList, master: master, as: ReadingListSyncPayload.self) { item, payload in
            SyncWireItem<ReadingListSyncPayload>(
                clientId: payload.id.uuidString,
                clientUpdatedAt: item.clientUpdatedAt,
                deleted: item.deleted,
                payload: payload,
                updatedAt: item.updatedAt
            )
        }
        readingListStore.replaceForSync(
            ReadingListSync.merge(base: readingListStore.items, remote: decrypted)
        )
    }

    private func clearReadingListPending(_ serverIDs: Set<String>, master: String) {
        let real = readingListStore.pendingDeletions.keys.filter {
            serverIDs.contains(SyncCrypto.hmacClientID($0.uuidString, domain: .readingList, masterKeyBase64: master))
        }
        readingListStore.clearPendingDeletions(Set(real.map(\.uuidString)))
    }

    private func collectShortcuts(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        shortcutStore.shortcuts.map {
            encryptedWire(domain: .keyboardShortcuts, realID: $0.id,
                          clientUpdatedAt: $0.updatedAt, deleted: false,
                          payload: ShortcutSync.payload($0), master: master)
        }
    }

    private func applyShortcuts(_ items: [SyncWireItem<SyncEncryptedPayload>], master: String) {
        let decrypted = decryptItems(items, domain: .keyboardShortcuts, master: master, as: ShortcutSyncPayload.self) { item, payload in
            SyncWireItem<ShortcutSyncPayload>(
                clientId: payload.id,
                clientUpdatedAt: item.clientUpdatedAt,
                deleted: item.deleted,
                payload: payload,
                updatedAt: item.updatedAt
            )
        }
        shortcutStore.replaceForSync(
            ShortcutSync.merge(base: shortcutStore.shortcuts, remote: decrypted)
        )
    }

    // MARK: - 设置 KV 域(键名也加密:线上 client_id = HMAC(键名))

    private func collectSettings(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        let snapshot = loadSettingsSnapshot()
        var stamps = loadSettingsStamps()
        let now = Date()
        var items: [SyncWireItem<SyncEncryptedPayload>] = []
        for entry in SettingsSync.catalog {
            guard let value = entry.read(settings) else { continue }
            let stamp: Date
            if snapshot[entry.key] != value {
                stamp = now
                stamps[entry.key] = now
            } else {
                stamp = stamps[entry.key] ?? now
            }
            let payload = SettingsSyncEntryPayload(key: entry.key, value: value)
            items.append(encryptedWire(domain: .settings, realID: entry.key,
                                       clientUpdatedAt: stamp, deleted: false,
                                       payload: payload, master: master))
        }
        saveSettingsStamps(stamps)
        return items
    }

    private func applySettings(_ items: [SyncWireItem<SyncEncryptedPayload>], master: String) {
        var stamps = loadSettingsStamps()
        var snapshot = loadSettingsSnapshot()
        for item in items {
            guard item.deleted != true, let envelope = item.payload else { continue }
            guard let payload = try? SyncCrypto.decrypt(
                envelope, domain: .settings, masterKeyBase64: master,
                as: SettingsSyncEntryPayload.self) else { continue }
            guard let entry = SettingsSync.entry(forKey: payload.key),
                  entry.apply(settings, payload.value) else { continue }
            stamps[payload.key] = item.clientUpdatedAt
            snapshot[payload.key] = payload.value
        }
        saveSettingsStamps(stamps)
        saveSettingsSnapshot(snapshot)
    }

    /// 本机即时写入（桥/测试用）：应用 + 盖戳 + 记快照，下个周期自然上推。
    func applyExternalSetting(key: String, value: SettingsSyncValue) -> Bool {
        guard let entry = SettingsSync.entry(forKey: key), entry.apply(settings, value) else {
            return false
        }
        let now = Date()
        var stamps = loadSettingsStamps()
        stamps[key] = now
        saveSettingsStamps(stamps)
        var snapshot = loadSettingsSnapshot()
        snapshot[key] = value
        saveSettingsSnapshot(snapshot)
        return true
    }

    private func loadSettingsStamps() -> [String: Date] {
        guard let data = defaults.data(forKey: settingsStampsKey) else { return [:] }
        return (try? SyncJSON.makeDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private func saveSettingsStamps(_ stamps: [String: Date]) {
        defaults.set(try? SyncJSON.makeEncoder().encode(stamps), forKey: settingsStampsKey)
    }

    private func loadSettingsSnapshot() -> [String: SettingsSyncValue] {
        guard let data = defaults.data(forKey: settingsSnapshotKey) else { return [:] }
        return (try? SyncJSON.makeDecoder().decode([String: SettingsSyncValue].self, from: data)) ?? [:]
    }

    private func saveSettingsSnapshot(_ snapshot: [String: SettingsSyncValue]) {
        defaults.set(try? SyncJSON.makeEncoder().encode(snapshot), forKey: settingsSnapshotKey)
    }

    // MARK: - 加解密小工具

    private func encryptedWire<T: Encodable>(
        domain: SyncDomain, realID: String, clientUpdatedAt: Date?,
        deleted: Bool, payload: T?, master: String
    ) -> SyncWireItem<SyncEncryptedPayload> {
        let envelope: SyncEncryptedPayload?
        if let payload, !deleted {
            envelope = try? SyncCrypto.encrypt(payload, domain: domain, masterKeyBase64: master)
        } else {
            envelope = nil
        }
        return SyncWireItem(
            clientId: SyncCrypto.hmacClientID(realID, domain: domain, masterKeyBase64: master),
            clientUpdatedAt: clientUpdatedAt ?? .distantPast,
            deleted: deleted,
            payload: envelope,
            updatedAt: nil
        )
    }

    /// 解密一批线路条目;解不开(密钥不对/密文损坏)的条目跳过——
    /// 指纹校验已在前,走到这里的失败通常是个别历史脏数据。
    private func decryptItems<T: Decodable>(
        _ items: [SyncWireItem<SyncEncryptedPayload>], domain: SyncDomain, master: String,
        as type: T.Type,
        rebuild: (SyncWireItem<SyncEncryptedPayload>, T) -> SyncWireItem<T>
    ) -> [SyncWireItem<T>] {
        var out: [SyncWireItem<T>] = []
        out.reserveCapacity(items.count)
        for item in items {
            if item.deleted == true { continue }
            guard let envelope = item.payload else { continue }
            guard let payload = try? SyncCrypto.decrypt(
                envelope, domain: domain, masterKeyBase64: master, as: type) else { continue }
            out.append(rebuild(item, payload))
        }
        return out
    }

    // MARK: - 令牌 / 设备 / Keychain

    private func cursorKey(_ domain: SyncDomain) -> String {
        "sync.cursor.\(domain.rawValue)"
    }

    /// access 优先；缺失/被清时用 refresh 换新（服务端轮换：旧的即 revoked）。
    private func validAccessToken() async throws -> String {
        if let access = keychainReadString(accessAccount), !access.isEmpty { return access }
        guard let refresh = keychainReadString(refreshAccount), !refresh.isEmpty else {
            throw SyncAPIError.unauthorized
        }
        let pair = try await SyncAPIClient.refresh(baseURL: serverBaseURL, refreshToken: refresh)
        storeTokens(pair)
        return pair.accessToken
    }

    private func storeTokens(_ pair: SyncTokenPair) {
        keychainWrite(Data(pair.accessToken.utf8), account: accessAccount)
        keychainWrite(Data(pair.refreshToken.utf8), account: refreshAccount)
    }

    private func deviceBody() -> SyncDeviceBody {
        let id: String
        if let stored = defaults.string(forKey: deviceIDKey), !stored.isEmpty {
            id = stored
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: deviceIDKey)
        }
        let name = Host.current().localizedName ?? "Mac"
        return SyncDeviceBody(deviceID: id, name: name, platform: "macOS")
    }

    // MARK: - Keychain（照 AgentPreferenceStore 的既有范式）

    /// 非交互读:ACL 失配时宁可读不到（显示未配置），不许同步等一个看不见的授权窗。
    private func keychainReadData(_ account: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func keychainReadString(_ account: String) -> String? {
        keychainReadData(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func keychainWrite(_ data: Data, account: String) {
        keychainDelete(account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func keychainDelete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
