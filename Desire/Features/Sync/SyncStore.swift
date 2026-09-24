import Combine
import Foundation
import LocalAuthentication
import Security

/// 云同步会话与编排（Store 层）：登录态（令牌存 Keychain）、每域拉取游标、
/// 立即/定时同步。策略 = 每周期"全量 push + 游标增量 pull"，LWW 仲裁在服务端
/// （书签树/快拨/阅读列表/快捷键四个域，结构见各 Sync 合并文件）。
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

    // Keychain（service = bundle id，account 前缀 sync-）
    private let keychainService = "me.siwi.Desire"
    private let accessAccount = "sync-access-token"
    private let refreshAccount = "sync-refresh-token"

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
        if let username = defaults.string(forKey: usernameKey),
           keychainRead(accessAccount) != nil || keychainRead(refreshAccount) != nil {
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

    /// 启动后的首次同步 + 定时器。AppState.init 末尾调用（自己内部再延迟，
    /// 不占启动路径）。
    func startAutoSync() {
        if syncTimer == nil {
            syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.syncNow()
                }
            }
        }
        guard case .signedIn = authState else { return }
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
        if let refresh = keychainRead(refreshAccount) {
            let base = serverBaseURL
            Task.detached {
                _ = try? await SyncAPIClient.logout(baseURL: base, refreshToken: refresh)
            }
        }
        keychainDelete(accessAccount)
        keychainDelete(refreshAccount)
        defaults.removeObject(forKey: usernameKey)
        authState = .signedOut
        lastError = nil
    }

    // MARK: - 同步

    /// 各域 push + pull。已登录且空闲才执行；401 时刷新令牌并整体重试一次。
    func syncNow() async {
        guard case .signedIn = authState, !isSyncing else { return }
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
        try await runDomainSync(.bookmarks, token: token,
                                collectPush: collectBookmarks,
                                applyRemote: applyBookmarks,
                                clearApplied: { bookmarkStore.clearPendingDeletions($0) })
        try await runDomainSync(.quickDials, token: token,
                                collectPush: collectQuickDials,
                                applyRemote: applyQuickDials,
                                clearApplied: { quickDialStore.clearPendingDeletions($0) })
        try await runDomainSync(.readingList, token: token,
                                collectPush: collectReadingList,
                                applyRemote: applyReadingList,
                                clearApplied: { readingListStore.clearPendingDeletions($0) })
        try await runDomainSync(.keyboardShortcuts, token: token,
                                collectPush: collectShortcuts,
                                applyRemote: applyShortcuts,
                                clearApplied: { _ in })
        try await runDomainSync(.settings, token: token,
                                collectPush: collectSettings,
                                applyRemote: applySettings,
                                clearApplied: { _ in })
        lastSyncAt = Date()
        defaults.set(lastSyncAt, forKey: lastSyncKey)
    }

    /// 单域骨架：全量 push → conflict 胜者落地 → 清已 applied 的待删 →
    /// 游标增量 pull → 合并回写 → 游标推进到末条 updated_at 原文。
    private func runDomainSync<P: Codable>(
        _ domain: SyncDomain,
        token: String,
        collectPush: () -> [SyncWireItem<P>],
        applyRemote: ([SyncWireItem<P>]) -> Void,
        clearApplied: (Set<String>) -> Void
    ) async throws {
        let base = serverBaseURL
        let results = try await SyncAPIClient.push(
            baseURL: base, domain: domain.rawValue, items: collectPush(), accessToken: token
        )
        let winners = results.compactMap { $0.status == "conflict" ? $0.item : nil }
        if !winners.isEmpty { applyRemote(winners) }
        clearApplied(Set(results.filter { $0.status == "applied" }.map(\.clientId)))

        let since = defaults.string(forKey: cursorKey(domain))
        let response: SyncPullResponse<P> = try await SyncAPIClient.pull(
            baseURL: base, domain: domain.rawValue, since: since, accessToken: token
        )
        if !response.items.isEmpty {
            applyRemote(response.items)
            defaults.set(response.items.last?.updatedAt, forKey: cursorKey(domain))
        }
    }

    // MARK: - 各域 adapter

    private func collectBookmarks() -> [SyncWireItem<BookmarkSyncPayload>] {
        var items = BookmarkSync.flatten(bookmarkStore.bookmarks).map { entry in
            SyncWireItem<BookmarkSyncPayload>(
                clientId: entry.id.uuidString,
                clientUpdatedAt: entry.updatedAt,
                deleted: false,
                payload: entry.payload,
                updatedAt: nil
            )
        }
        for (id, deletedAt) in bookmarkStore.pendingDeletions {
            items.append(SyncWireItem(
                clientId: id.uuidString,
                clientUpdatedAt: deletedAt,
                deleted: true,
                payload: nil,
                updatedAt: nil
            ))
        }
        return items
    }

    private func applyBookmarks(_ items: [SyncWireItem<BookmarkSyncPayload>]) {
        bookmarkStore.replaceForSync(
            BookmarkSync.merge(base: bookmarkStore.bookmarks, remote: items)
        )
    }

    private func collectQuickDials() -> [SyncWireItem<QuickDialSyncPayload>] {
        var items = quickDialStore.dials.map {
            syncWire(id: $0.id.uuidString, updatedAt: $0.updatedAt, payload: QuickDialSync.payload($0))
        }
        for (id, deletedAt) in quickDialStore.pendingDeletions {
            items.append(SyncWireItem(
                clientId: id.uuidString, clientUpdatedAt: deletedAt,
                deleted: true, payload: nil, updatedAt: nil
            ))
        }
        return items
    }

    private func applyQuickDials(_ items: [SyncWireItem<QuickDialSyncPayload>]) {
        quickDialStore.replaceForSync(
            QuickDialSync.merge(base: quickDialStore.dials, remote: items)
        )
    }

    private func collectReadingList() -> [SyncWireItem<ReadingListSyncPayload>] {
        var items = readingListStore.items.map {
            syncWire(id: $0.id.uuidString, updatedAt: $0.updatedAt, payload: ReadingListSync.payload($0))
        }
        for (id, deletedAt) in readingListStore.pendingDeletions {
            items.append(SyncWireItem(
                clientId: id.uuidString, clientUpdatedAt: deletedAt,
                deleted: true, payload: nil, updatedAt: nil
            ))
        }
        return items
    }

    private func applyReadingList(_ items: [SyncWireItem<ReadingListSyncPayload>]) {
        readingListStore.replaceForSync(
            ReadingListSync.merge(base: readingListStore.items, remote: items)
        )
    }

    private func collectShortcuts() -> [SyncWireItem<ShortcutSyncPayload>] {
        ShortcutSync.flatten(shortcutStore.shortcuts)
    }

    private func applyShortcuts(_ items: [SyncWireItem<ShortcutSyncPayload>]) {
        shortcutStore.replaceForSync(
            ShortcutSync.merge(base: shortcutStore.shortcuts, remote: items)
        )
    }

    // MARK: - 设置 KV 域

    /// 设置没有 per-key updatedAt：本地变更靠"当前值 vs 上次同步快照"diff 检测，
    /// 变了就盖新戳（= 本机最新意图），没变沿用旧戳交给服务端 LWW 仲裁。
    private func collectSettings() -> [SyncWireItem<SettingsSyncValue>] {
        let snapshot = loadSettingsSnapshot()
        var stamps = loadSettingsStamps()
        let now = Date()
        var items: [SyncWireItem<SettingsSyncValue>] = []
        for entry in SettingsSync.catalog {
            guard let value = entry.read(settings) else { continue }
            let stamp: Date
            if snapshot[entry.key] != value {
                stamp = now
                stamps[entry.key] = now
            } else {
                stamp = stamps[entry.key] ?? now
            }
            items.append(SyncWireItem(
                clientId: entry.key, clientUpdatedAt: stamp,
                deleted: false, payload: value, updatedAt: nil
            ))
        }
        saveSettingsStamps(stamps)
        return items
    }

    private func applySettings(_ items: [SyncWireItem<SettingsSyncValue>]) {
        var stamps = loadSettingsStamps()
        var snapshot = loadSettingsSnapshot()
        for item in items {
            guard let payload = item.payload,
                  let entry = SettingsSync.entry(forKey: item.clientId),
                  entry.apply(settings, payload) else { continue }
            stamps[item.clientId] = item.clientUpdatedAt
            snapshot[item.clientId] = payload
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

    // MARK: - 令牌 / 设备 / Keychain

    private func cursorKey(_ domain: SyncDomain) -> String {
        "sync.cursor.\(domain.rawValue)"
    }

    /// access 优先；缺失/被清时用 refresh 换新（服务端轮换：旧的即 revoked）。
    private func validAccessToken() async throws -> String {
        if let access = keychainRead(accessAccount), !access.isEmpty { return access }
        guard let refresh = keychainRead(refreshAccount), !refresh.isEmpty else {
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

    /// 非交互读：ACL 失配时宁可读不到（显示未登录），不许同步等一个看不见的授权窗。
    private func keychainRead(_ account: String) -> String? {
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
        return String(data: data, encoding: .utf8)
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
