import Combine
import Foundation
import LocalAuthentication
import Security

/// 云同步会话与编排（Store 层）：登录态（令牌存 Keychain）、每域拉取游标、
/// 立即/定时同步。首域 = 书签（全量 push + 增量 pull，LWW 仲裁在服务端）。
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

    static let defaultServerBaseURL = "http://127.0.0.1:18090"

    private let bookmarkStore: BookmarkStore
    private var syncTimer: Timer?
    private let defaults = UserDefaults.standard

    // UserDefaults keys
    private let usernameKey = "sync.username"
    private let serverKey = "sync.serverBaseURL"
    private let deviceIDKey = "sync.deviceID"
    private let bookmarkCursorKey = "sync.cursor.bookmarks"
    private let lastSyncKey = "sync.lastSyncAt"

    // Keychain（service = bundle id，account 前缀 sync-）
    private let keychainService = "me.siwi.Desire"
    private let accessAccount = "sync-access-token"
    private let refreshAccount = "sync-refresh-token"

    /// 定时同步间隔（5 分钟；书签量小，全量 push 无压力）。
    private let syncInterval: TimeInterval = 300

    init(bookmarkStore: BookmarkStore) {
        self.bookmarkStore = bookmarkStore
        if let username = defaults.string(forKey: usernameKey),
           keychainRead(accessAccount) != nil || keychainRead(refreshAccount) != nil {
            authState = .signedIn(username: username)
        }
        lastSyncAt = defaults.object(forKey: lastSyncKey) as? Date
    }

    var serverBaseURL: String {
        let stored = defaults.string(forKey: serverKey) ?? ""
        return stored.isEmpty ? Self.defaultServerBaseURL : stored
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

    /// push 全量树 + 待删 tombstone → pull 增量合并。已登录且空闲才执行；
    /// 401 时刷新令牌并整体重试一次。
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
                recordFailure(error)
            }
        } catch {
            recordFailure(error)
        }
    }

    private func runSyncCycle() async throws {
        let token = try await validAccessToken()
        let base = serverBaseURL

        // 1) push：全量树 + 本机待删 tombstone（删除必须显式推 tombstone，
        //    否则其他设备 pull 回来会把本地已删的节点救活）
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
        let results = try await SyncAPIClient.push(
            baseURL: base, domain: SyncDomain.bookmarks.rawValue, items: items, accessToken: token
        )
        // 2) 冲突仲裁：服务端胜者直接落地（push 的 LWW 已保证它比本机推送更新）
        let winners = results.compactMap { $0.status == "conflict" ? $0.item : nil }
        if !winners.isEmpty {
            let merged = BookmarkSync.merge(base: bookmarkStore.bookmarks, remote: winners)
            bookmarkStore.replaceForSync(merged)
        }
        // 推送成功的 tombstone 从本机待删清单移除（服务端已持久化）
        let appliedClientIDs = Set(results.filter { $0.status == "applied" }.map(\.clientId))
        bookmarkStore.clearPendingDeletions(appliedClientIDs)

        // 3) pull 增量（游标 = 服务端 updated_at 原文，严格大于）
        let response: SyncPullResponse<BookmarkSyncPayload> = try await SyncAPIClient.pull(
            baseURL: base, domain: SyncDomain.bookmarks.rawValue,
            since: defaults.string(forKey: bookmarkCursorKey), accessToken: token
        )
        if !response.items.isEmpty {
            let merged = BookmarkSync.merge(base: bookmarkStore.bookmarks, remote: response.items)
            bookmarkStore.replaceForSync(merged)
            defaults.set(response.items.last?.updatedAt, forKey: bookmarkCursorKey)
        }
        lastSyncAt = Date()
        defaults.set(lastSyncAt, forKey: lastSyncKey)
    }

    private func recordFailure(_ error: Error) {
        lastError = error.localizedDescription
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

    // MARK: - Keychain（照 AgentPreferenceStore 的既有范式）

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
