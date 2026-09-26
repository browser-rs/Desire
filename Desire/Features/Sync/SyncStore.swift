import AppKit
import Combine
import Foundation
import LocalAuthentication
import Network
import Security

/// 云同步会话与编排（Store 层）：登录态（令牌存 Keychain）、每域拉取游标、
/// 变更驱动的近实时同步。策略：
/// - **push 走脏域门控**：源 store 的 objectWillChange → 标脏 → 5 秒防抖后
///   只上推脏域（`applyingRemote` 守卫保证远端合并回写不再标脏）；启动/登录
///   首轮全脏做全量对账；push 失败保留脏标记，退避重试（5s 翻倍至 5min 封顶）。
/// - **pull 始终游标增量**，每 5 分钟定时巡检 + 唤醒/联网恢复时补一轮。
/// - LWW 仲裁在服务端；单域失败不阻断其他域（结果见 domainStatus）。
///
/// **E2E 加密**：主密钥（256 位）只在客户端 Keychain，永不上传；每个域用
/// HKDF 派生独立密钥做 AES-256-GCM 载荷加密，client_id 用独立派生密钥做
/// HMAC（服务器只见不透明标签）。服务器另有密钥托管（密码包裹的 DEK）用于
/// 新设备恢复。见 SyncCrypto。
///
/// Keychain 读全部 `interactive: false`（LAContext interactionNotAllowed）——
/// 启动/回合中路径禁止触发隐窗授权（v0.3.14 教训，见 AGENTS）。
@MainActor
final class SyncStore: ObservableObject {

    enum AuthState: Equatable {
        case signedOut
        case signedIn(username: String)
    }

    /// 单域最近一次同步结果（设置页逐域展示）。
    enum DomainStatus: Equatable {
        case ok(Date)
        case failed(String)
    }

    @Published private(set) var authState: AuthState = .signedOut
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncAt: Date?
    /// 最近一次同步/登录失败的展示文本；成功后清空。只在**手动**同步失败时刷新
    /// （自动同步的失败落在 domainStatus 里，不拿后台网络抖动打扰用户）。
    @Published private(set) var lastError: String?
    private var lastAuthError: Error?
    /// 各域最近一次同步结果（ok 时间 / failed 文案）。
    @Published private(set) var domainStatus: [SyncDomain: DomainStatus] = [:]
    /// 同步服务器地址（设置页/桥可改，立即生效）。
    @Published private(set) var serverBaseURL: String
    /// 用户选择的同步类目（缺省全开）。关闭 = 跳过该域 push/pull；
    /// 游标保留，重新打开后自动补齐关闭期间的增量；服务端数据不删。
    @Published private(set) var enabledDomains: [SyncDomain: Bool] = [:]
    /// E2E 主密钥是否已在 Keychain。没有密钥时同步被阻止（无法加解密）。
    @Published private(set) var hasSyncKey = false
    /// 密钥指纹（16 位 hex），设置页展示用于跨设备核对。
    @Published private(set) var syncKeyFingerprint: String?
    /// 当前待用的注册验证码（nil = 未加载/已消费）
    @Published private(set) var captcha: CaptchaInfo?

    /// 默认同步服务器（生产）。本地开发/测试用桥 `POST /sync/server` 钉回
    /// 本地实例（见 AGENTS 测试铁律：app 驱动的 E2E 前必须钉本地）。
    static let defaultServerBaseURL = "https://api.mankong.icu/v9"

    private let bookmarkStore: BookmarkStore
    private let quickDialStore: QuickDialStore
    private let readingListStore: ReadingListStore
    private let historyStore: HistoryStore
    private let shortcutStore: KeyboardShortcutStore
    private let settings: Settings
    private let agentPreferenceStore: AgentPreferenceStore
    private let agentMemoryStore = AgentMemoryStore.shared
    private var syncTimer: Timer?
    private let defaults = UserDefaults.standard

    // MARK: 变更驱动同步的状态

    /// 本地有未上推变更的域。源 store 的 objectWillChange 标脏；push 成功才清
    /// （collect 与清标记在同一个同步块里，网络期间的新变更会重新标脏，不丢）。
    private var dirtyDomains: Set<SyncDomain> = []
    /// 远端合并回写（push 胜者落地 / pull 合并 / 清 pending）期间的守卫：
    /// objectWillChange 在属性写**之前**同步触发，这段窗口内的通知不是本地变更。
    private var applyingRemote = false
    /// 防抖任务（nil = 无排程；同一窗口内的多次变更合并成一次同步）。
    private var changeSyncTask: Task<Void, Never>?
    /// 自动重试间隔：5s 起步，失败翻倍，封顶 300s（退化为定时器节奏）。
    private var changeSyncDelay: TimeInterval = changeDebounceSeconds
    /// 网络可达性（离线时自动同步静默跳过；手动照常执行并如实报错）。
    private var isOnline = true
    private let pathMonitor = NWPathMonitor()
    private var cancellables: Set<AnyCancellable> = []

    // 常量 nonisolated：默认参数值等非隔离上下文也要读（Swift 6 下是错误）。
    nonisolated static let changeDebounceSeconds: TimeInterval = 5
    nonisolated static let maxRetryDelaySeconds: TimeInterval = 300
    /// 服务端 push 单请求条数上限 500（MAX_PUSH_ITEMS），客户端分块留余量。
    nonisolated static let pushChunkSize = 400
    /// 服务端 pull 固定页大小（PULL_LIMIT，请求不带 limit 参数）。
    nonisolated static let pullPageSize = 1000

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

    struct CaptchaInfo {
        let id: String
        let pngData: Data
        let devCode: String?
    }

    /// 定时巡检间隔(5 分钟):push 走脏域门控(变更后 5 秒级防抖),pull 始终游标
    /// 增量,定时轮只是其他设备变更的兜底拉取。
    private let syncInterval: TimeInterval = 300

    init(
        bookmarkStore: BookmarkStore,
        quickDialStore: QuickDialStore,
        readingListStore: ReadingListStore,
        historyStore: HistoryStore,
        shortcutStore: KeyboardShortcutStore,
        settings: Settings,
        agentPreferenceStore: AgentPreferenceStore
    ) {
        self.bookmarkStore = bookmarkStore
        self.quickDialStore = quickDialStore
        self.readingListStore = readingListStore
        self.historyStore = historyStore
        self.shortcutStore = shortcutStore
        self.settings = settings
        self.agentPreferenceStore = agentPreferenceStore
        let storedServer = defaults.string(forKey: serverKey) ?? ""
        serverBaseURL = storedServer.isEmpty ? Self.defaultServerBaseURL : storedServer
        for domain in SyncDomain.allCases {
            // 浏览历史 opt-in（高频日志型数据 + 隐私敏感），默认关；其余域默认开
            let fallback = domain == .history ? false : true
            enabledDomains[domain] = defaults.object(forKey: enabledKey(domain)) as? Bool ?? fallback
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
        // 变更驱动：源 store 一动就标脏 + 排防抖同步。注意 AgentPreferenceStore
        // 的任何变化（不只提示词）都会标脏 agentPrefs——多标无害（未变化的
        // collect 返回空、不产生 push），换来的是订阅层零特判。
        observeLocalChanges(bookmarkStore.objectWillChange, domain: .bookmarks)
        observeLocalChanges(quickDialStore.objectWillChange, domain: .quickDials)
        observeLocalChanges(readingListStore.objectWillChange, domain: .readingList)
        observeLocalChanges(shortcutStore.objectWillChange, domain: .keyboardShortcuts)
        observeLocalChanges(settings.objectWillChange, domain: .settings)
        observeLocalChanges(agentPreferenceStore.objectWillChange, domain: .agentPrefs)
        observeLocalChanges(agentMemoryStore.objectWillChange, domain: .agentMemory)
        observeLocalChanges(historyStore.objectWillChange, domain: .history)
    }

    private func observeLocalChanges(
        _ publisher: ObservableObjectPublisher, domain: SyncDomain
    ) {
        publisher
            .sink { [weak self] _ in self?.noteLocalChange(domain) }
            .store(in: &cancellables)
    }

    // MARK: - 变更驱动调度

    private func noteLocalChange(_ domain: SyncDomain) {
        guard !applyingRemote else { return }
        dirtyDomains.insert(domain)
        scheduleChangeSync()
    }

    /// 排一次防抖同步（已有排程则合并）。isSyncing 时不特殊处理：syncNow
    /// 会把这次调用转成"轮次结束后补排"，脏标记不会丢。
    private func scheduleChangeSync(after delay: TimeInterval = changeDebounceSeconds) {
        guard case .signedIn = authState, hasSyncKey, changeSyncTask == nil else { return }
        changeSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.changeSyncTask = nil
            await self.syncNow(isAuto: true)
        }
    }

    /// 一轮结束后的收尾：还有脏域（轮次中途新变更 / push 失败）就再排一场；
    /// 失败场景指数退避，避免对挂掉的服务器 5 秒一撞。
    private func settleAutoFollowUp(hadFailure: Bool) {
        guard case .signedIn = authState, hasSyncKey, !dirtyDomains.isEmpty else { return }
        if hadFailure {
            changeSyncDelay = min(changeSyncDelay * 2, Self.maxRetryDelaySeconds)
        } else {
            changeSyncDelay = Self.changeDebounceSeconds
        }
        scheduleChangeSync(after: changeSyncDelay)
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                // 断网期间积压的本地变更，恢复联网立刻补推。
                if online { self.scheduleChangeSync() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "me.siwi.Desire.sync.path"))
    }

    /// 睡眠唤醒后补一轮（其他设备睡眠期间的下发 + 本机积压上推）。
    /// 延 10 秒等网络栈就绪；离线则由 isOnline 门控自然跳过。
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.syncNow(isAuto: true)
            }
        }
    }

    /// 桥/调试用：某域是否有未上推的本地变更。
    func isDirty(_ domain: SyncDomain) -> Bool {
        dirtyDomains.contains(domain)
    }

    // MARK: - 退出前补推（applicationShouldTerminate）

    /// 是否值得在退出前补推：已登录、有密钥、不在同步中、有脏域。
    var needsQuitFlush: Bool {
        guard case .signedIn = authState, hasSyncKey, !isSyncing else { return false }
        return !dirtyDomains.isEmpty
    }

    /// 退出前限时补推：**只 push 脏域、不 pull**（pull 对退出无意义且耗时），
    /// 单域失败互相不挡，全部 best-effort；推不上去的域放回脏集合（下次启动
    /// 启动首轮全量对账兜底）。无论成败 **5 秒内必回调 onDone**（应用必须退出）。
    func flushOnQuit(onDone: @escaping @MainActor () -> Void) {
        guard needsQuitFlush else { onDone(); return }
        guard let master = masterKeyBase64 else { onDone(); return }
        let pending = domainAdapters.filter { isEnabled($0.domain) && dirtyDomains.contains($0.domain) }
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            onDone()
        }
        let deadlineTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            finish()
        }
        Task { @MainActor in
            defer { deadlineTask.cancel() }
            guard let token = try? await validAccessToken() else { finish(); return }
            for adapter in pending {
                guard !finished else { return }
                dirtyDomains.remove(adapter.domain)
                let items = adapter.collect(master)
                guard !items.isEmpty else { continue }
                do {
                    let results = try await pushChunked(domain: adapter.domain, items: items, token: token)
                    adapter.commit()
                    let winners = results.compactMap { $0.status == "conflict" ? $0.item : nil }
                    applyRemotely {
                        if !winners.isEmpty { adapter.apply(winners, master) }
                        adapter.clear(Set(results.map(\.clientId)), master)
                    }
                } catch {
                    dirtyDomains.insert(adapter.domain)
                }
            }
            finish()
        }
    }

    func setServerBaseURL(_ url: String) {
        var trimmed = url.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }   // 尾斜杠会造成 //auth/… 双斜杠
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
        // 重新打开：关闭期间积压的本地变更（脏标记一直在）即刻防抖补推，
        // 不等 5 分钟兜底轮。
        if enabled { scheduleChangeSync() }
    }

    // MARK: - E2E 主密钥

    private var masterKeyBase64: String? {
        keychainReadData(masterKeyAccount)?.base64EncodedString()
    }

    /// 拉取一张新的注册验证码（图片 + id；dev 环境附明文码）。
    func loadCaptcha() async {
        do {
            let resp = try await SyncAPIClient.captcha(baseURL: serverBaseURL)
            guard let data = Data(base64Encoded: resp.image) else {
                throw SyncAPIError.network(String(localized: "Sync server returned invalid data"))
            }
            captcha = CaptchaInfo(id: resp.captchaId, pngData: data, devCode: resp.code)
        } catch {
            captcha = nil
        }
    }

    // MARK: - 启动后的首次同步 + 定时器

    func startAutoSync() {
        if syncTimer == nil {
            syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.syncNow(isAuto: true)
                }
            }
        }
        startNetworkMonitoring()
        observeWake()
        guard case .signedIn = authState, hasSyncKey else { return }
        // 启动首轮全脏：对账本地未上推的变更（含上次会话遗留的 tombstone）。
        dirtyDomains = Set(SyncDomain.allCases)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await self.syncNow(isAuto: true)
        }
    }

    // MARK: - 登录 / 注册 / 退出

    func login(username: String, password: String) async throws {
        try await authenticate(username: username, password: password,
                               register: false, captchaCode: nil)
    }

    func register(username: String, password: String, captchaCode: String? = nil) async throws {
        try await authenticate(username: username, password: password,
                               register: true, captchaCode: captchaCode)
    }

    private func authenticate(
        username: String, password: String, register: Bool, captchaCode: String?
    ) async throws {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        var body = SyncAuthBody(
            username: trimmed,
            password: password,
            nickname: nil,
            device: deviceBody()
        )
        var pair: SyncTokenPair?
        // 注册:验证码可能过期(5 分钟 TTL)/被消费 → 失败后换新码重试一次
        for attempt in 0...(register ? 1 : 0) {
            if register {
                if captcha == nil || attempt > 0 { await loadCaptcha() }
                guard let cap = captcha else {
                    throw SyncAPIError.server(String(localized: "Failed to load the verification code"))
                }
                body.captchaId = cap.id
                body.captchaCode = captchaCode ?? cap.devCode
            }
            do {
                if register {
                    pair = try await SyncAPIClient.register(baseURL: serverBaseURL, body: body)
                } else {
                    pair = try await SyncAPIClient.login(baseURL: serverBaseURL, body: body)
                }
                break
            } catch let err as SyncAPIError {
                // 401 = 验证码/凭据类失败:换一张新验证码重试一次(第二次仍失败则抛出)
                guard attempt == 0, case .unauthorized = err else { throw err }
                captcha = nil
            }
        }
        guard let pair else {
            throw lastAuthError ?? SyncAPIError.server(String(localized: "Sync session expired"))
        }
        storeTokens(pair)
        defaults.set(trimmed, forKey: usernameKey)
        authState = .signedIn(username: trimmed)
        lastError = nil
        // E2E 密钥生命周期(密码仍在作用域):注册 = 首次托管;登录 = 从托管恢复
        try await restoreOrEscrowDEK(password: password)
        // 登录/注册后首轮全脏:本地存量(含换账号场景)全部与服务器对账一遍
        dirtyDomains = Set(SyncDomain.allCases)
        await syncNow()
    }

    /// E2E 密钥生命周期核心(登录/注册成功后调用,密码在作用域内):
    /// - 服务器已有托管 → 用密码解包恢复 DEK(服务器为权威,覆盖本机旧值);
    /// - 无托管(首台设备/旧版升级) → 用本机 DEK(无则新生成)包裹上报;
    /// - 解包失败(托管损坏/密码在别处被改后数据未轮换) → 明确抛错,同步阻止。
    private func restoreOrEscrowDEK(password: String) async throws {
        let escrow = try await SyncAPIClient.keyEscrow(
            baseURL: serverBaseURL, accessToken: validAccessToken())
        if let salt = escrow.kdfSalt, !salt.isEmpty,
           let wrapped = escrow.wrappedDek, !wrapped.isEmpty {
            let restored = try SyncCrypto.unwrapDEK(wrapped, password: password, saltBase64: salt)
            guard let data = Data(base64Encoded: restored) else {
                throw SyncCrypto.CryptoError.invalidKeyFormat
            }
            keychainWrite(data, account: masterKeyAccount)
            hasSyncKey = true
            syncKeyFingerprint = try SyncCrypto.fingerprint(masterKeyBase64: restored)
            return
        }
        // 首台设备:沿用本机已有 DEK(兼容旧版加密数据),没有则新生成
        let dek: String
        if let existing = masterKeyBase64, SyncCrypto.isValidMasterKeyBase64(existing) {
            dek = existing
        } else {
            dek = SyncCrypto.generateMasterKey()
        }
        let salt = SyncCrypto.generateSalt()
        let wrapped = try SyncCrypto.wrapDEK(dekBase64: dek, password: password, saltBase64: salt)
        let check = try SyncCrypto.keyCheckHex(masterKeyBase64: dek)
        try await SyncAPIClient.setKeyEscrow(
            baseURL: serverBaseURL, accessToken: validAccessToken(),
            body: SyncEscrowBody(kdfSalt: salt, wrappedDek: wrapped, keyCheck: check))
        keychainWrite(Data(base64Encoded: dek)!, account: masterKeyAccount)
        hasSyncKey = true
        syncKeyFingerprint = try SyncCrypto.fingerprint(masterKeyBase64: dek)
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
        dirtyDomains = []
        domainStatus = [:]
        changeSyncTask?.cancel()
        changeSyncTask = nil
        changeSyncDelay = Self.changeDebounceSeconds
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
            throw SyncAPIError.unauthorized(message: nil)
        }
        let trimmedNew = new.trimmingCharacters(in: .whitespaces)
        let hasLetter = trimmedNew.contains(where: { $0.isLetter })
        let hasDigit = trimmedNew.contains(where: { $0.isNumber })
        guard trimmedNew.count >= 8, trimmedNew.count <= 72, hasLetter, hasDigit else {
            throw SyncAPIError.server(String(localized: "Password must be 8-72 characters and include letters and numbers"))
        }
        // E2E 换包:同一个 DEK 用新密码重新包裹,既有密文保持可解
        let dek = masterKeyBase64
        guard let dek, SyncCrypto.isValidMasterKeyBase64(dek) else {
            throw SyncCrypto.CryptoError.invalidKeyFormat
        }
        let newSalt = SyncCrypto.generateSalt()
        let wrapped = try SyncCrypto.wrapDEK(dekBase64: dek, password: trimmedNew,
                                             saltBase64: newSalt)
        try await SyncAPIClient.changePassword(
            baseURL: serverBaseURL,
            accessToken: validAccessToken(),
            body: SetPasswordReq(oldPassword: current, newPassword: trimmedNew,
                                 newKdfSalt: newSalt, newWrappedDek: wrapped)
        )
    }

    // MARK: - 同步

    /// 各域 push（仅脏域）+ pull（全部启用域）。已登录、有密钥且空闲才执行；
    /// 401 时刷新令牌并整体重试一次。isAuto = 定时/防抖/唤醒触发的后台轮次：
    /// 离线静默跳过，失败只落 domainStatus；手动失败才刷新全局 lastError。
    func syncNow(isAuto: Bool = false) async {
        if isSyncing {
            // 正在跑的轮次收集不到这批变更——结束后补排一场（见 settleAutoFollowUp）。
            scheduleChangeSync()
            return
        }
        guard case .signedIn = authState else { return }
        guard hasSyncKey else {
            if !isAuto {
                lastError = String(localized: "Set a sync key first — sync stays local until then.")
            }
            return
        }
        if isAuto && !isOnline { return }
        isSyncing = true
        defer { isSyncing = false }
        var outcome = SyncCycleOutcome()
        do {
            outcome = try await runSyncCycle()
        } catch SyncAPIError.unauthorized {
            // access 过期：强制刷新后整体重试一次
            keychainDelete(accessAccount)
            do {
                _ = try await validAccessToken()
                outcome = try await runSyncCycle()
            } catch let refreshError as SyncAPIError {
                if case .unauthorized = refreshError {
                    // refresh 也被服务端拒绝（吊销/轮换丢失/服务端换密钥）：
                    // 会话已死——干净登出并给出明确指引，不再每轮空转报 401。
                    handleSessionExpired()
                    outcome = failAllEnabledDomains(
                        String(localized: "Sync session expired — please sign in again."))
                } else {
                    outcome = failAllEnabledDomains(refreshError.localizedDescription)
                }
            } catch {
                outcome = failAllEnabledDomains(error.localizedDescription)
            }
        } catch {
            outcome = failAllEnabledDomains(error.localizedDescription)
        }
        if outcome.hasFailure {
            if !isAuto { lastError = outcome.errorText() }
        } else {
            lastError = nil
        }
        if outcome.anySuccess {
            lastSyncAt = Date()
            defaults.set(lastSyncAt, forKey: lastSyncKey)
        }
        settleAutoFollowUp(hadFailure: outcome.hasFailure)
    }

    /// 令牌/主密钥级失败（影响所有启用域）：全部启用域记失败，汇总口径统一。
    private func failAllEnabledDomains(_ message: String) -> SyncCycleOutcome {
        var outcome = SyncCycleOutcome()
        for adapter in domainAdapters where isEnabled(adapter.domain) {
            outcome.failed[adapter.domain] = message
            domainStatus[adapter.domain] = .failed(message)
        }
        return outcome
    }

    /// refresh 令牌被服务端拒绝（吊销/轮换丢失/服务端换 JWT 密钥）：
    /// 清干净本地会话回到未登录态。主密钥保留（设备所有），重新登录即自动恢复；
    /// 游标/戳按账号语义清空，重登走全量对账（与 logout 同口径）。
    private func handleSessionExpired() {
        keychainDelete(accessAccount)
        keychainDelete(refreshAccount)
        defaults.removeObject(forKey: usernameKey)
        clearSyncState()
        authState = .signedOut
        domainStatus = [:]
        changeSyncTask?.cancel()
        changeSyncTask = nil
        changeSyncDelay = Self.changeDebounceSeconds
        lastError = String(localized: "Sync session expired — please sign in again.")
    }

    /// 单域适配器：collect 本机状态（加密）→ push → 冲突胜者落地 → 清已裁决
    /// tombstone → 游标增量 pull → 合并回写。**新增域 = 在 domainAdapters 加一行
    /// + init 里订阅源 store**（observeLocalChanges），脏标记/防抖/隔离自动生效。
    private struct DomainAdapter {
        let domain: SyncDomain
        let collect: (String) -> [SyncWireItem<SyncEncryptedPayload>]
        let apply: ([SyncWireItem<SyncEncryptedPayload>], String) -> Void
        let clear: (Set<String>, String) -> Void
        /// push 全部成功后调用（settings/agentPrefs 用它把"待生效快照"落盘；
        /// 收集时先攒着，push 失败就不落，下轮以更新戳重推）。
        let commit: () -> Void

        init(
            domain: SyncDomain,
            collect: @escaping (String) -> [SyncWireItem<SyncEncryptedPayload>],
            apply: @escaping ([SyncWireItem<SyncEncryptedPayload>], String) -> Void,
            clear: @escaping (Set<String>, String) -> Void,
            commit: (() -> Void)? = nil
        ) {
            self.domain = domain
            self.collect = collect
            self.apply = apply
            self.clear = clear
            self.commit = commit ?? {}
        }
    }

    private var domainAdapters: [DomainAdapter] {
        [
            DomainAdapter(domain: .bookmarks, collect: collectBookmarks, apply: applyBookmarks, clear: clearBookmarksPending),
            DomainAdapter(domain: .quickDials, collect: collectQuickDials, apply: applyQuickDials, clear: clearQuickDialsPending),
            DomainAdapter(domain: .readingList, collect: collectReadingList, apply: applyReadingList, clear: clearReadingListPending),
            DomainAdapter(domain: .keyboardShortcuts, collect: collectShortcuts, apply: applyShortcuts, clear: { _, _ in }),
            DomainAdapter(domain: .settings, collect: collectSettings, apply: applySettings, clear: { _, _ in },
                          commit: { self.commitSettingsSnapshot() }),
            DomainAdapter(domain: .agentMemory, collect: collectAgentMemory, apply: applyAgentMemory, clear: clearAgentMemoryPending),
            DomainAdapter(domain: .agentPrefs, collect: collectAgentPrefs, apply: applyAgentPrefs, clear: { _, _ in },
                          commit: { self.commitAgentPrefsSnapshot() }),
            DomainAdapter(domain: .history, collect: collectHistory, apply: applyHistory, clear: clearHistoryPending),
        ]
    }

    private func runSyncCycle() async throws -> SyncCycleOutcome {
        let token = try await validAccessToken()
        guard let master = masterKeyBase64 else {
            throw SyncCrypto.CryptoError.invalidKeyFormat
        }
        var outcome = SyncCycleOutcome()
        for adapter in domainAdapters where isEnabled(adapter.domain) {
            do {
                try await runDomainSync(adapter, token: token, master: master)
                outcome.succeeded.insert(adapter.domain)
                domainStatus[adapter.domain] = .ok(Date())
            } catch {
                // 401 = 令牌过期，抛给上层整体刷新重试；其余按域隔离，不阻断其他域。
                if let syncError = error as? SyncAPIError, case .unauthorized = syncError {
                    throw error
                }
                let message = error.localizedDescription
                outcome.failed[adapter.domain] = message
                domainStatus[adapter.domain] = .failed(message)
            }
        }
        return outcome
    }

    /// 远端数据落地（push 胜者 / pull 合并 / 清 pending）一律包在这里：
    /// objectWillChange 在属性写**之前**同步触发，守卫窗口内的通知不是本地变更
    /// ——否则拉取回来的数据会把自己标脏，形成推拉互振。
    private func applyRemotely(_ body: () -> Void) {
        applyingRemote = true
        body()
        applyingRemote = false
    }

    /// push 分块：服务端单请求上限 500 条（MAX_PUSH_ITEMS），大书签库全量对账
    /// 一发会被整单拒绝；按 400 一块顺序推，结果聚合。
    private func pushChunked(
        domain: SyncDomain, items: [SyncWireItem<SyncEncryptedPayload>], token: String
    ) async throws -> [SyncPushResult<SyncEncryptedPayload>] {
        var results: [SyncPushResult<SyncEncryptedPayload>] = []
        results.reserveCapacity(items.count)
        let base = serverBaseURL
        var index = items.startIndex
        while index < items.endIndex {
            let end = items.index(index, offsetBy: Self.pushChunkSize, limitedBy: items.endIndex) ?? items.endIndex
            let chunkResults: [SyncPushResult<SyncEncryptedPayload>] = try await SyncAPIClient.push(
                baseURL: base, domain: domain.rawValue,
                items: Array(items[index..<end]), accessToken: token
            )
            results.append(contentsOf: chunkResults)
            index = end
        }
        return results
    }

    /// 单域骨架：脏域才 push（空集合不发请求）→ 冲突胜者落地 → 清已裁决的
    /// 待删 → 游标增量 pull（整页则继续翻页）→ 合并回写 → 游标推进到末条。
    private func runDomainSync(
        _ adapter: DomainAdapter, token: String, master: String
    ) async throws {
        let domain = adapter.domain
        var pushResults: [SyncPushResult<SyncEncryptedPayload>] = []
        if dirtyDomains.contains(domain) {
            // 先摘脏标记再 collect：collect 同步执行，此后网络窗口内的新变更会
            // 重新标脏，不会被这次 push 吞掉。push 失败则放回脏集合等退避重试。
            dirtyDomains.remove(domain)
            let items = adapter.collect(master)
            if !items.isEmpty {
                do {
                    pushResults = try await pushChunked(domain: domain, items: items, token: token)
                } catch {
                    dirtyDomains.insert(domain)
                    throw error
                }
                adapter.commit()
                let winners = pushResults.compactMap { $0.status == "conflict" ? $0.item : nil }
                applyRemotely {
                    if !winners.isEmpty { adapter.apply(winners, master) }
                    // applied 与 conflict 都代表"服务端已权威裁决"：applied 是本机赢了,
                    // conflict 是服务端赢了(胜者已落地)。两种情况下待删清单里的旧 tombstone
                    // 都该清掉——否则输掉 LWW 的删除会每周期重推一遍,永远 conflict。
                    adapter.clear(Set(pushResults.map(\.clientId)), master)
                }
            }
        }

        // pull 增量。游标是复合的 "updated_at|id"——仅凭时间戳时,同刻行恰跨
        // 分页边界会被 `> since` 永久跳过(静默丢失)。返回整页(=服务端页大小)
        // 说明可能还有下一页,翻到不足一页为止;中途失败游标不落盘,下轮重拉(幂等)。
        let cursor = defaults.string(forKey: cursorKey(domain))
        var since: String?
        var sinceID: Int64?
        if let cursor, !cursor.isEmpty {
            let parts = cursor.split(separator: "|", maxSplits: 1).map(String.init)
            since = parts.first
            sinceID = parts.count > 1 ? Int64(parts[1]) : nil
        }
        var finalCursor: String?
        var pages = 0
        while pages < 50 {
            pages += 1
            let response: SyncPullResponse<SyncEncryptedPayload> = try await SyncAPIClient.pull(
                baseURL: serverBaseURL, domain: domain.rawValue,
                since: since, sinceID: sinceID, accessToken: token
            )
            if response.items.isEmpty { break }
            applyRemotely { adapter.apply(response.items, master) }
            if let last = response.items.last {
                finalCursor = "\(last.updatedAt ?? "")|\(last.id ?? 0)"
                since = last.updatedAt
                sinceID = last.id
            }
            if response.items.count < Self.pullPageSize { break }
        }
        if let finalCursor {
            defaults.set(finalCursor, forKey: cursorKey(domain))
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

    /// collect 期间攒下的"推送后生效"快照（push 成功才落盘，见 DomainAdapter.commit）。
    private var pendingSettingsSnapshot: [String: SettingsSyncValue]?
    private var pendingAgentPrefsSnapshot: [String: SettingsSyncValue]?

    /// 只推与"上次已知值"不同的键（快照 diff）。快照缺键 = 首推或清账号状态后
    /// 的全量补齐。旧实现每轮都推全部条目：本地改过的键在 collect 时盖新戳但
    /// 快照不更新，下轮 diff 仍不等 → 戳越盖越新、每 5 分钟重推一遍。
    private func collectSettings(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        var snapshot = loadSettingsSnapshot()
        var stamps = loadSettingsStamps()
        let now = Date()
        var items: [SyncWireItem<SyncEncryptedPayload>] = []
        for entry in SettingsSync.catalog {
            guard let value = entry.read(settings) else { continue }
            guard snapshot[entry.key] != value else { continue }
            snapshot[entry.key] = value
            stamps[entry.key] = now
            let payload = SettingsSyncEntryPayload(key: entry.key, value: value)
            items.append(encryptedWire(domain: .settings, realID: entry.key,
                                       clientUpdatedAt: now, deleted: false,
                                       payload: payload, master: master))
        }
        if !items.isEmpty {
            pendingSettingsSnapshot = snapshot
            saveSettingsStamps(stamps)
        }
        return items
    }

    private func commitSettingsSnapshot() {
        if let snapshot = pendingSettingsSnapshot {
            saveSettingsSnapshot(snapshot)
            pendingSettingsSnapshot = nil
        }
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

    // MARK: - Agent 记忆域（画像 / 事实 / 摘要；对话本身留本地）

    private func collectAgentMemory(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        var items: [SyncWireItem<SyncEncryptedPayload>] = []
        // 画像
        items.append(encryptedWire(
            domain: .agentMemory, realID: "profile",
            clientUpdatedAt: agentMemoryStore.archive.profileUpdatedAt,
            deleted: false, payload: agentMemoryStore.archive.profile, master: master))
        // 事实
        for fact in agentMemoryStore.archive.facts {
            items.append(encryptedWire(
                domain: .agentMemory, realID: fact.id.uuidString,
                clientUpdatedAt: fact.updatedAt, deleted: false,
                payload: AgentMemoryItem.fact(fact), master: master))
        }
        // 摘要
        for summary in agentMemoryStore.archive.summaries {
            items.append(encryptedWire(
                domain: .agentMemory, realID: summary.id.uuidString,
                clientUpdatedAt: summary.createdAt, deleted: false,
                payload: AgentMemoryItem.summary(summary), master: master))
        }
        // 待删 tombstone
        for (id, deletedAt) in agentMemoryStore.pendingDeletions {
            items.append(encryptedTombstone(
                domain: .agentMemory, realID: id, clientUpdatedAt: deletedAt, master: master))
        }
        return items
    }

    private func applyAgentMemory(_ items: [SyncWireItem<SyncEncryptedPayload>], master: String) {
        let snapshot = AgentMemorySnapshot(
            profile: agentMemoryStore.archive.profile,
            profileUpdatedAt: agentMemoryStore.archive.profileUpdatedAt,
            facts: agentMemoryStore.archive.facts,
            summaries: agentMemoryStore.archive.summaries)
        // 本机条目的 HMAC 反查表:远端 tombstone 只有 HMAC,靠它找到本机真实 id
        var factHMAC: [String: UUID] = [:]
        var summaryHMAC: [String: UUID] = [:]
        for fact in snapshot.facts {
            factHMAC[SyncCrypto.hmacClientID(fact.id.uuidString, domain: .agentMemory, masterKeyBase64: master)] = fact.id
        }
        for summary in snapshot.summaries {
            summaryHMAC[SyncCrypto.hmacClientID(summary.id.uuidString, domain: .agentMemory, masterKeyBase64: master)] = summary.id
        }
        let profileID = SyncCrypto.hmacClientID("profile", domain: .agentMemory, masterKeyBase64: master)

        var changes: [AgentMemoryChange] = []
        changes.reserveCapacity(items.count)
        for item in items {
            let stamp = item.clientUpdatedAt
            if item.clientId == profileID {
                guard item.deleted != true, let envelope = item.payload else { continue }
                guard let profile = try? SyncCrypto.decrypt(
                    envelope, domain: .agentMemory, masterKeyBase64: master,
                    as: UserProfile.self) else { continue }
                changes.append(AgentMemoryChange(
                    realID: "profile", clientUpdatedAt: stamp, deleted: false,
                    item: .profile(profile)))
                continue
            }
            if item.deleted == true {
                if let factID = factHMAC[item.clientId] {
                    changes.append(AgentMemoryChange(
                        realID: factID.uuidString, clientUpdatedAt: stamp, deleted: true, item: nil))
                } else if let summaryID = summaryHMAC[item.clientId] {
                    changes.append(AgentMemoryChange(
                        realID: summaryID.uuidString, clientUpdatedAt: stamp, deleted: true, item: nil))
                }
                continue
            }
            guard let envelope = item.payload else { continue }
            guard let payload = try? SyncCrypto.decrypt(
                envelope, domain: .agentMemory, masterKeyBase64: master,
                as: AgentMemoryItem.self) else { continue }
            let realID: String
            switch payload {
            case .fact(let fact): realID = fact.id.uuidString
            case .summary(let summary): realID = summary.id.uuidString
            case .profile: realID = "profile"
            }
            changes.append(AgentMemoryChange(
                realID: realID, clientUpdatedAt: stamp, deleted: false, item: payload))
        }
        let merged = AgentMemorySync.apply(base: snapshot, changes: changes)
        var archive = agentMemoryStore.archive
        archive.profile = merged.profile
        archive.profileUpdatedAt = merged.profileUpdatedAt
        archive.facts = merged.facts
        archive.summaries = merged.summaries
        agentMemoryStore.replaceForSync(archive)
    }

    private func clearAgentMemoryPending(_ serverIDs: Set<String>, master: String) {
        agentMemoryStore.clearPendingDeletions(serverIDs) { realID in
            SyncCrypto.hmacClientID(realID, domain: .agentMemory, masterKeyBase64: master)
        }
    }

    // MARK: - Agent 偏好域（自定义系统提示词）

    private static let agentPromptKey = "system-prompt"

    private func collectAgentPrefs(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        let key = Self.agentPromptKey
        var snapshot = loadSettingsSnapshot()
        var stamps = loadSettingsStamps()
        let now = Date()
        let value = agentPreferenceStore.systemPrompt
        // 提示词相对"上次已知值"无变化 → 不推（collect 空数组 = 本轮不发请求）。
        guard snapshot[key] != .string(value) else { return [] }
        snapshot[key] = .string(value)
        stamps[key] = now
        saveSettingsStamps(stamps)
        pendingAgentPrefsSnapshot = snapshot
        let payload = AgentPrefsSyncPayload(systemPrompt: value)
        return [encryptedWire(domain: .agentPrefs, realID: key,
                              clientUpdatedAt: now, deleted: false,
                              payload: payload, master: master)]
    }

    private func commitAgentPrefsSnapshot() {
        if let snapshot = pendingAgentPrefsSnapshot {
            saveSettingsSnapshot(snapshot)
            pendingAgentPrefsSnapshot = nil
        }
    }

    private func applyAgentPrefs(_ items: [SyncWireItem<SyncEncryptedPayload>], master: String) {
        var stamps = loadSettingsStamps()
        var snapshot = loadSettingsSnapshot()
        for item in items {
            guard item.deleted != true, let envelope = item.payload else { continue }
            guard let payload = try? SyncCrypto.decrypt(
                envelope, domain: .agentPrefs, masterKeyBase64: master,
                as: AgentPrefsSyncPayload.self) else { continue }
            agentPreferenceStore.systemPrompt = payload.systemPrompt
            stamps[Self.agentPromptKey] = item.clientUpdatedAt
            snapshot[Self.agentPromptKey] = .string(payload.systemPrompt)
        }
        saveSettingsStamps(stamps)
        saveSettingsSnapshot(snapshot)
    }

    /// 本机即时写入（桥/测试用）：应用 + 盖戳 + 标脏（**不写快照**——快照语义是
    /// "与服务器已一致"，写快照会让这次变更永远推不上去），下个防抖周期上推。
    func applyExternalSetting(key: String, value: SettingsSyncValue) -> Bool {
        guard let entry = SettingsSync.entry(forKey: key), entry.apply(settings, value) else {
            return false
        }
        var stamps = loadSettingsStamps()
        stamps[key] = Date()
        saveSettingsStamps(stamps)
        dirtyDomains.insert(.settings)
        scheduleChangeSync()
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

    // MARK: - 历史域（opt-in；服务端专表 + 90 天 TTL）

    private func collectHistory(master: String) -> [SyncWireItem<SyncEncryptedPayload>] {
        var items = historyStore.entries.map {
            encryptedWire(domain: .history, realID: $0.id.uuidString,
                          clientUpdatedAt: $0.updatedAt ?? $0.timestamp, deleted: false,
                          payload: HistorySync.payload($0), master: master)
        }
        for (id, deletedAt) in historyStore.pendingDeletions {
            items.append(encryptedTombstone(
                domain: .history, realID: id.uuidString,
                clientUpdatedAt: deletedAt, master: master))
        }
        return items
    }

    private func applyHistory(_ items: [SyncWireItem<SyncEncryptedPayload>], master: String) {
        let decrypted = decryptItems(items, domain: .history, master: master, as: HistorySyncPayload.self) { item, payload in
            SyncWireItem<HistorySyncPayload>(
                clientId: payload.id.uuidString,
                clientUpdatedAt: item.clientUpdatedAt,
                deleted: item.deleted,
                payload: payload,
                updatedAt: item.updatedAt
            )
        }
        historyStore.replaceForSync(
            HistorySync.merge(base: historyStore.entries, remote: decrypted)
        )
    }

    private func clearHistoryPending(_ serverIDs: Set<String>, master: String) {
        let real = historyStore.pendingDeletions.keys.filter {
            serverIDs.contains(SyncCrypto.hmacClientID($0.uuidString, domain: .history, masterKeyBase64: master))
        }
        historyStore.clearPendingDeletions(Set(real))
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
            throw SyncAPIError.unauthorized(message: nil)
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
