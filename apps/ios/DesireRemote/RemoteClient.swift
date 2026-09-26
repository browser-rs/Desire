import Combine
import Foundation
import SwiftUI
import UIKit

/// 远程会话客户端：登录 → 扫码/导入配对 → 中继 → 与 Mac 上的 Agent 对话。
/// 信道端到端加密（会话密钥来自配对二维码，服务器不可读）。
///
/// 传输拓扑（与 Mac 端 RemoteControlStore 对齐，服务端可水平扩展）：
/// - **上行一律 REST** `POST /remote/push`（E2E 密文入库 + 服务器 express 发布）。
/// - **下行 = WS 频道订阅（express，即时） + 前台 1s `GET /remote/pull` 兜底**，
///   两条路径按信箱行 id 去重后走同一处理函数。WS 不承载业务帧。
/// - 20s `sendPing` 探活 + 保活；断线 `wsTask = nil` → 5s→30s 退避重连。
/// - 令牌：401 → 刷新重试一次；刷新也失败 → 清会话回登录页。
///   （此前 access token 过期后 WS 永远 401、界面永远"已断开"，即此根因。）
@MainActor
final class RemoteClient: ObservableObject {

    enum Phase: Equatable {
        /// 登录过期/未登录（唯一强制回登录页的情形）
        case login
        /// 已登录主页面：未配对显示连接引导，已配对显示聊天
        case main
    }

    struct RemoteSessionInfo: Identifiable, Codable, Equatable {
        var id: String
        var label: String
        var busy: Bool
        var count: Int
        /// 最近更新时间（epoch 秒；Mac 端 conversation.updatedAt）
        var date: Double?

        var dateValue: Date? {
            date.map { Date(timeIntervalSince1970: $0) }
        }
    }

    @Published var phase: Phase = .login
    /// 服务器覆盖地址：空 = 使用内置默认（内置地址不在界面露出）
    @Published var customServer: String
    @Published var username = ""
    @Published var password = ""
    @Published var loginError: String?
    @Published var isWorking = false
    @Published var pairError: String?
    @Published var desktopName: String?
    @Published var connectionState = "未连接"
    @Published var messages: [ChatMessage] = []
    @Published var busy = false
    /// Mac 离线时发出的消息（排队中，上线后送达）
    @Published var queuedOffline = false
    /// Mac 上的会话列表（聊天记录）
    @Published var sessions: [RemoteSessionInfo] = []
    /// 当前查看的会话 id（nil = Mac 当前活跃会话）
    @Published var selectedSessionID: String?
    /// 本地即时回显的临时用户消息（快照到达后被覆盖）
    @Published var pendingEcho: ChatMessage?
    /// Mac 在线（服务器 last_seen 判定；pull 响应携带）
    @Published private(set) var desktopOnline = true
    /// Agent 状态行（快照携带）：模型 / 上下文占用% / 排队数 / 回合已用时秒
    @Published private(set) var agentModel = ""
    @Published private(set) var contextPercent = 0
    @Published private(set) var queueCount = 0
    @Published private(set) var elapsedSeconds: Int?
    /// Agent 记忆（nil = 未加载；看板打开时拉取）
    @Published private(set) var memory: AgentMemory?

    // MARK: 人工介入 / 进度（快照携带，与 Mac 端 RemoteSnapshotFrame 对齐）

    /// 待审批的工具调用（非 nil = Agent 正挂起等 Allow / Deny）
    @Published private(set) var approval: RemoteApproval?
    /// Agent 的反问（非 nil = askUser 正挂起等回答）
    @Published private(set) var question: RemoteQuestion?
    /// updatePlan 任务清单
    @Published private(set) var plan: [RemotePlanStep] = []
    /// 子代理实时进度
    @Published private(set) var subagents: [RemoteSubagent] = []
    /// 回合进行中输入、排队待发的消息
    @Published private(set) var queued: [RemoteQueued] = []
    /// Agent 将要操作的目标页（"Title — host"）
    @Published private(set) var contextLabel: String?
    /// FULL ACCESS：所有工具免审批（据此解释"为何不弹审批"）
    @Published private(set) var fullAccess = false
    /// 上一轮已结束 → 可重新生成
    @Published private(set) var canRegenerate = false
    /// 快捷动作（Mac 为唯一文案来源）
    @Published private(set) var quickActions: [RemoteQuickAction] = []
    /// 回合被暂停（面板"继续"按钮据此显示）
    @Published private(set) var paused = false
    /// 已发出「停止」，但 Mac 还没确认。
    ///
    /// 取消只能在**检查点**生效：Agent 正卡在一个不可中断的工具里时（例如
    /// `executeJS`／下载），快照要过一会儿才回 `busy=false`。中间这段时间界面
    /// 必须告诉用户"已经收到，正在停"，否则点下去毫无反馈、看着就是没反应。
    @Published private(set) var stopping = false
    /// 本对话累计 token / 成本（未填单价时 cost 为 nil——不显示 0）
    @Published private(set) var tokens: Int?
    @Published private(set) var cost: String?

    // MARK: 按需拉取的只读信息（能力 / 统计 / 轨迹 / 模型）
    //
    // 这四类数据量比状态大，Mac 端只在手机主动请求时回一帧；页面进入时
    // 拉一次 + 支持下拉刷新即可，不进每秒快照。

    /// Agent 可调用的工具（含风险分级）+ 技能库
    @Published private(set) var capabilities: RemoteCapabilities?
    /// 跨会话用量统计
    @Published private(set) var stats: RemoteStats?
    /// 当前会话的轨迹（按回合）
    @Published private(set) var trace: RemoteTrace?
    /// 模型服务档案 + 当前档案的候选模型
    @Published private(set) var models: RemoteModels?

    /// 已保存的配对（重新打开 App 直接进控制台）。
    @Published private(set) var hasSavedPairing = false

    // MARK: - 主题

    /// 外观：system / light / dark（设置页可改，持久化）。
    @Published var appearance: String {
        didSet { defaults.set(appearance, forKey: "remote.appearance") }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private let defaults = UserDefaults.standard
    private var accessToken: String?
    private var sessionKeyB64: String?
    private var desktopDeviceID: String?
    private var controllerName: String
    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var pullFailures = 0
    /// 已处理过的信箱帧 id（WS express 先到时，兜底 pull 的同 id 行跳过）
    private var processedIDs: Set<Int64> = []
    /// 刚请求新建会话：下一帧快照的 session 字段即新会话 id，据此锁定选中
    private var pendingNewSession = false
    /// 会话列表延迟刷新（写操作后等 Mac 回包，1.8s 兜底；多次触发合并）
    private var sessionsRefreshTask: Task<Void, Never>?

    /// 内置生产地址（不出现在任何界面文案里；可被覆盖设置替换）
    static let builtinServer = "https://api.mankong.icu/v9"

    convenience init() {
        self.init(appearance: "")
    }

    init(appearance _: String) {
        appearance = UserDefaults.standard.string(forKey: "remote.appearance") ?? "system"
        // 迁移：旧版把内置默认地址写进了覆盖位——清掉，地址不再于界面露出
        let savedServer = defaults.string(forKey: "remote.server") ?? ""
        if savedServer == Self.builtinServer {
            defaults.removeObject(forKey: "remote.server")
        }
        customServer = savedServer == Self.builtinServer ? "" : savedServer
        controllerName = UIDevice.current.name
        migrateSecretsToKeychain()
        if let token = KeychainStore.get("remote.access"),
           let key = KeychainStore.get("remote.sessionKey"),
           let desktop = KeychainStore.get("remote.desktopID") {
            // 令牌/配对密钥在 Keychain——卸载重装后自动恢复登录与配对
            accessToken = token
            sessionKeyB64 = key
            desktopDeviceID = desktop
            hasSavedPairing = true
            phase = .main
            username = KeychainStore.get("remote.username")
                ?? defaults.string(forKey: "remote.username") ?? ""
            // Mac 名字也从本地恢复：否则冷启动后是 nil，界面会渲染成
            // "未连接 Mac"（而链路其实是通的）。随后每帧快照会校正它。
            desktopName = defaults.string(forKey: "remote.desktopName")
            // 恢复持久化的对话记录（杀 App 不丢）
            if let data = defaults.data(forKey: "remote.messages"),
               let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                messages = saved
            }
            busy = defaults.bool(forKey: "remote.busy")
            connectWS()
            startPullLoop()
            // 冷启动恢复配对时也要拉一次会话列表——此前只在"配对成功"和
            // 写操作后拉取，杀进程重开后列表永远是空的。
            requestSessions()
        }
    }

    /// 规范化后的服务器地址（扫码登录时与二维码 payload 的 s 字段比对）
    var normalizedServerURL: String {
        let chosen = customServer.isEmpty ? Self.builtinServer : customServer
        var base = chosen.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private var baseURL: String { normalizedServerURL }

    // MARK: - 登录

    func login() {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        isWorking = true
        loginError = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let deviceID = savedOrCreateDeviceID()
                let body = LoginBody(
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password,
                    device: .init(device_id: deviceID,
                                  device_name: UIDevice.current.name,
                                  platform: "iOS"))
                let pair: TokenPair = try await API.send(
                    "POST", baseURL, "/auth/login",
                    body: try JSONEncoder().encode(body))
                accessToken = pair.accessToken
                KeychainStore.set(pair.accessToken, account: "remote.access")
                KeychainStore.set(pair.refreshToken, account: "remote.refresh")
                // 服务器覆盖：只在用户显式设置过时持久化（空 = 内置默认）
                if !customServer.isEmpty {
                    defaults.set(baseURL, forKey: "remote.server")
                }
                defaults.set(username, forKey: "remote.username")
                phase = .main
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    /// 一次性迁移：旧版把令牌/配对密钥放 UserDefaults（卸载即丢）——
    /// 迁入 Keychain（重装保留），随后清掉 UserDefaults 副本。
    private func migrateSecretsToKeychain() {
        for key in ["remote.access", "remote.refresh", "remote.sessionKey", "remote.desktopID", "remote.username"] {
            if let value = defaults.string(forKey: key) {
                if KeychainStore.get(key) == nil {
                    KeychainStore.set(value, account: key)
                }
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func savedOrCreateDeviceID() -> String {
        if let id = defaults.string(forKey: "remote.deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "remote.deviceID")
        return id
    }

    // MARK: - 令牌（401 → 刷新重试一次；刷新失败回登录页）

    private func currentToken() async throws -> String {
        if let accessToken { return accessToken }
        return try await forceRefresh()
    }

    /// 刷新单飞（single-flight）：并发请求共用一个刷新任务。
    ///
    /// refresh token 在服务端是**一次性的**——每次刷新即吊销旧的、轮换发新的
    /// （`auth_service::refresh` 的 `UPDATE ... revoked_at`）。此前 pull 轮询、
    /// push 上行、WS 重连会各自发起刷新：两个并发请求拿着同一个旧 token，
    /// 第二个必然被服务端拒（"refresh token revoked"），而旧代码把任何失败都
    /// 当成会话过期 → 清凭证回登录页。现象就是"莫名其妙被退出登录"。
    private var refreshTask: Task<String, Error>?

    private func forceRefresh() async throws -> String {
        if let existing = refreshTask { return try await existing.value }
        let task = Task<String, Error> { [weak self] in
            guard let self else { throw APIError.server("登录已过期，请重新登录") }
            defer { self.refreshTask = nil }
            return try await self.performRefresh()
        }
        refreshTask = task
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let refresh = KeychainStore.get("remote.refresh") else {
            throw sessionExpired()
        }
        do {
            let refreshed: TokenPair = try await API.send(
                "POST", baseURL, "/auth/refresh",
                body: try JSONEncoder().encode(["refresh_token": refresh]))
            accessToken = refreshed.accessToken
            KeychainStore.set(refreshed.accessToken, account: "remote.access")
            KeychainStore.set(refreshed.refreshToken, account: "remote.refresh")
            return refreshed.accessToken
        } catch APIError.unauthorized {
            // 服务端明确拒绝（被吊销 / 过期 / 已被轮换过）：会话确实结束了
            throw sessionExpired()
        } catch {
            // 网络抖动 / 服务端 5xx / 解析失败：**不能**清会话。
            // 此前 catch 兜底所有错误都清凭证，断网一次或服务器抖一下就把用户
            // 踢回登录页——这是"退出登录"最常被误归因到 Mac 端动作的原因。
            throw error
        }
    }

    /// 会话彻底过期：清令牌回登录页（服务端轮换后旧 refresh 一律失效）。
    private func sessionExpired() -> APIError {
        accessToken = nil
        KeychainStore.set(nil, account: "remote.access")
        KeychainStore.set(nil, account: "remote.refresh")
        phase = .login
        connectionState = "登录已过期，请重新登录"
        return APIError.server("登录已过期，请重新登录")
    }

    /// 带令牌请求 + 401 自动刷新重试一次。
    private func authedSend<Response: Codable>(
        _ method: String, _ path: String, body: Data? = nil
    ) async throws -> Response {
        let token = try await currentToken()
        do {
            return try await API.send(method, baseURL, path, body: body, token: token)
        } catch APIError.unauthorized {
            let fresh = try await forceRefresh()
            return try await API.send(method, baseURL, path, body: body, token: fresh)
        }
    }

    /// 设置页修改服务器覆盖地址：空 = 清除覆盖回内置默认
    /// （需重新登录才生效到令牌层面）。
    func saveServerURL(_ url: String) {
        var base = url.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        customServer = base
        if base.isEmpty {
            defaults.removeObject(forKey: "remote.server")
        } else {
            defaults.set(base, forKey: "remote.server")
        }
    }

    var savedUsername: String {
        defaults.string(forKey: "remote.username") ?? ""
    }

    func logout() {
        KeychainStore.set(nil, account: "remote.access")
        KeychainStore.set(nil, account: "remote.refresh")
        stopAllTransports()
        accessToken = nil
        phase = .login
    }

    // MARK: - 配对（扫码 / 粘贴导入）

    /// 登录二维码里顺带带来的配对信息（Mac 侧「远程控制」开着时才会带）。
    struct LoginPairingInfo {
        var code: String
        var sessionKeyB64: String
    }

    /// 扫码或粘贴得到**配对二维码**内容 → 解析 → 认领。
    func importPairing(_ raw: String) {
        pairError = nil
        guard let data = raw.data(using: .utf8),
              let qr = try? JSONDecoder().decode(PairingQRPayload.self, from: data) else {
            pairError = "二维码内容无法识别"
            return
        }
        // 配对二维码自带服务器地址——用户扫码即显式选择，作为覆盖存下
        saveServerURL(qr.s)
        isWorking = true
        let info = LoginPairingInfo(code: qr.c, sessionKeyB64: qr.k)
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await self.claimPairing(info)
            } catch {
                pairError = error.localizedDescription
            }
        }
    }

    /// 完成远程配对（认领）：写入会话密钥与桌面设备 id，进主界面并起链路。
    ///
    /// 两个入口共用：扫**配对码**，以及扫**登录码**时 Mac 顺带带过来的配对信息。
    /// 后者的存在意义是省掉"再扫一次配对码"——此前扫码登录只解决账号登录，
    /// 手机没有会话密钥（只在配对码里传），于是登录成功后仍卡在配对页。
    func claimPairing(_ info: LoginPairingInfo) async throws {
        sessionKeyB64 = info.sessionKeyB64
        let token = try await currentToken()
        let resp: ClaimResp = try await API.send(
            "POST", baseURL, "/remote/pairing/claim",
            body: try JSONEncoder().encode(
                ClaimBody(code: info.code, controller_name: controllerName)),
            token: token)
        desktopDeviceID = resp.desktopDeviceId
        desktopName = resp.desktopName
        defaults.set(resp.desktopName, forKey: "remote.desktopName")
        KeychainStore.set(info.sessionKeyB64, account: "remote.sessionKey")
        KeychainStore.set(resp.desktopDeviceId, account: "remote.desktopID")
        hasSavedPairing = true
        messages = []
        busy = false
        phase = .main
        connectWS()
        startPullLoop()
        requestSessions()
    }

    /// 回到前台：重连续 transports 并补快照。
    func appForegrounded() {
        guard hasSavedPairing, phase == .main else { return }
        startPullLoop()
        if wsTask == nil { connectWS() }
        requestSync()
        // 会话列表也补一次：Mac 侧可能在后台期间新增/重命名过会话
        requestSessions()
    }

    /// 退到后台：停轮询（省电）；WS 会被系统掐断，回前台统一重建。
    func appWentBackground() {
        pullTask?.cancel()
        pullTask = nil
    }

    /// 解除配对：先 best-effort 吊销服务器侧配对，再清本地。
    /// （此前只清本地——Mac 端设备列表里手机永远挂着。吊销失败时设备
    /// 仍留在 Mac 列表，可在 Mac 端手动吊销。）
    func unpair() {
        let token = accessToken
        let desktopID = desktopDeviceID
        stopAllTransports()
        KeychainStore.set(nil, account: "remote.sessionKey")
        KeychainStore.set(nil, account: "remote.desktopID")
        KeychainStore.set(nil, account: "remote.access")
        KeychainStore.set(nil, account: "remote.refresh")
        defaults.removeObject(forKey: "remote.messages")
        defaults.removeObject(forKey: "remote.busy")
        defaults.removeObject(forKey: "remote.desktopName")
        sessionKeyB64 = nil
        desktopDeviceID = nil
        accessToken = nil
        messages = []
        sessions = []
        pendingNewSession = false
        memory = nil
        agentModel = ""
        contextPercent = 0
        queueCount = 0
        elapsedSeconds = nil
        selectedSessionID = nil
        busy = false
        queuedOffline = false
        desktopOnline = true
        approval = nil
        question = nil
        plan = []
        subagents = []
        queued = []
        contextLabel = nil
        fullAccess = false
        canRegenerate = false
        quickActions = []
        paused = false
        tokens = nil
        cost = nil
        capabilities = nil
        stats = nil
        trace = nil
        models = nil
        connectionState = "未连接"
        hasSavedPairing = false
        phase = .main
        guard let token, let desktopID else { return }
        Task {
            let _: RevokeResp? = try? await API.send(
                "POST", baseURL, "/remote/pairing/revoke",
                body: try JSONEncoder().encode(
                    RevokeBody(desktop_device_id: desktopID, controller_name: controllerName)),
                token: token)
        }
    }

    private func stopAllTransports() {
        sessionsRefreshTask?.cancel()
        sessionsRefreshTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pullTask?.cancel()
        pullTask = nil
    }

    // MARK: - WebSocket（下行订阅 + 探活）

    private func connectWS() {
        guard hasSavedPairing, let desktopDeviceID else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = try await self.currentToken()
                var wsBase = self.baseURL
                if wsBase.hasPrefix("https://") {
                    wsBase = "wss://" + wsBase.dropFirst("https://".count)
                } else if wsBase.hasPrefix("http://") {
                    wsBase = "ws://" + wsBase.dropFirst("http://".count)
                }
                guard let url = URL(string: "\(wsBase)/remote/ws?role=controller&device=\(desktopDeviceID)") else {
                    return
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let task = URLSession.shared.webSocketTask(with: request)
                self.wsTask = task
                task.resume()
                if !self.connectionState.contains("工作中") {
                    self.connectionState = "连接中…"
                }
                self.startPingLoop(task)
                self.receiveLoop(task)
                self.requestSync()
            } catch {
                // 会话过期：sessionExpired() 已置回登录页；其余失败走重连
                if self.hasSavedPairing, self.phase != .login {
                    self.connectionState = "重连中…"
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard hasSavedPairing, phase != .login, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = min(30, 5 * reconnectAttempt)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connectWS()
        }
    }

    /// 20s sendPing：保活 + 半开连接探活（探活失败 = 链路已死，
    /// 主动拆掉触发重连，界面不再永远停在"已连接"的假象上）。
    private func startPingLoop(_ task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { break }
                task.sendPing { error in
                    guard error != nil else { return }
                    Task { @MainActor [weak self] in
                        self?.wsTaskDidDie(task)
                    }
                }
            }
        }
    }

    private func wsTaskDidDie(_ dead: URLSessionWebSocketTask) {
        guard wsTask === dead else { return }
        dead.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        connectionState = "重连中…"
        scheduleReconnect()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message?
                do {
                    message = try await task.receive()
                } catch {
                    break
                }
                guard let message, !Task.isCancelled else { break }
                let text: String
                switch message {
                case .string(let t): text = t
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                self?.handleExpressEnvelope(text)
            }
            guard !Task.isCancelled else { return }
            // 被动断开（新连接接管/登出时不走这儿）
            guard let self, self.wsTask === task else { return }
            self.wsTask = nil
            self.connectionState = "重连中…"
            self.scheduleReconnect()
        }
    }

    /// WS express 帧 = 信箱行 `{"id":..,"payload":".."}`（与 pull items 同形）。
    private func handleExpressEnvelope(_ text: String) {
        guard let data = text.data(using: .utf8),
              let item = try? JSONDecoder().decode(InboxItem.self, from: data) else { return }
        noteLinkActivity()
        ingestItems([item])
    }

    // MARK: - pull 兜底（前台 1s 一拍）

    private func startPullLoop() {
        guard pullTask == nil else { return }
        pullTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pullOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func pullOnce() async {
        guard let desktopDeviceID else { return }
        do {
            let resp: PullResp = try await authedSend(
                "GET", "/remote/pull?role=controller&device=\(desktopDeviceID)")
            pullFailures = 0
            desktopOnline = resp.desktopOnline ?? true
            ingestItems(resp.items)
            refreshConnectionText()
        } catch APIError.server(let message) where message.contains("登录已过期") {
            // 会话过期：sessionExpired() 已置回登录页
            stopAllTransports()
        } catch {
            pullFailures += 1
            if pullFailures >= 3 {
                connectionState = "重连中…"
            }
        }
    }

    private func ingestItems(_ items: [InboxItem]) {
        for item in items {
            guard !processedIDs.contains(item.id) else { continue }
            processedIDs.insert(item.id)
            if processedIDs.count > 500 { processedIDs.removeAll() }
            guard let sessionKeyB64,
                  let inner = RemoteCrypto.decrypt(payloadB64: item.payload, sessionKeyB64: sessionKeyB64)
            else { continue }
            handleInner(inner)
        }
    }

    /// 链路有活动：重连退避归零，界面回到连接态文案。
    private func noteLinkActivity() {
        reconnectAttempt = 0
        pullFailures = 0
        refreshConnectionText()
    }

    private func refreshConnectionText() {
        let target: String
        if busy {
            target = "Agent 工作中…"
        } else if !desktopOnline {
            target = "Mac 离线"
        } else if connectionState.contains("断开") || connectionState.contains("重连")
            || connectionState == "未连接" || connectionState == "连接中…" {
            target = "已连接"
        } else {
            return
        }
        if connectionState != target { connectionState = target }
    }

    // MARK: - 业务帧处理

    private func handleInner(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        // 具名回包（没有 messages/busy 字段，解不出 SnapshotFrame）先按 t 分发。
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let kind = root["t"] as? String, kind != "snapshot" {
            switch kind {
            case "memory":
                memory = try? JSONDecoder().decode(AgentMemory.self, from: data)
            case "sessions":
                if let list = root["list"] as? [[String: Any]] {
                    sessions = list.compactMap { item in
                        guard let id = item["id"] as? String, let label = item["label"] as? String else { return nil }
                        return RemoteSessionInfo(id: id, label: label,
                                                 busy: item["busy"] as? Bool ?? false,
                                                 count: item["count"] as? Int ?? 0,
                                                 date: item["date"] as? Double)
                    }
                }
            case "capabilities":
                capabilities = try? JSONDecoder().decode(RemoteCapabilities.self, from: data)
            case "stats":
                stats = try? JSONDecoder().decode(RemoteStats.self, from: data)
            case "trace":
                trace = try? JSONDecoder().decode(RemoteTrace.self, from: data)
            case "models":
                models = try? JSONDecoder().decode(RemoteModels.self, from: data)
            case "error":
                // Mac 端反馈（例如"没有活跃的 Agent 会话"）：显示成连接状态旁白。
                if let message = root["message"] as? String, !message.isEmpty {
                    connectionState = message
                }
            default:
                break
            }
            return
        }
        guard let frame = try? JSONDecoder().decode(SnapshotFrame.self, from: data) else { return }
        messages = frame.messages
        if pendingEcho != nil { pendingEcho = nil }
        if pendingNewSession, let sid = frame.session, !sid.isEmpty {
            pendingNewSession = false
            selectedSessionID = sid
        }
        busy = frame.busy
        // 相同值不发布：避免每秒快照触发全 UI 重绘（Menu 打开时的闪动源）
        let newModel = frame.model ?? ""
        if agentModel != newModel { agentModel = newModel }
        let newContext = frame.contextPercent ?? 0
        if contextPercent != newContext { contextPercent = newContext }
        let newQueue = frame.queueCount ?? 0
        if queueCount != newQueue { queueCount = newQueue }
        if elapsedSeconds != frame.elapsed { elapsedSeconds = frame.elapsed }
        // 人工介入 / 进度：相同值不发布（与上面同口径，防每秒快照触发全 UI 重绘）
        if approval != frame.approval { approval = frame.approval }
        if question != frame.question { question = frame.question }
        let newPlan = frame.plan ?? []
        if plan != newPlan { plan = newPlan }
        let newSubagents = frame.subagents ?? []
        if subagents != newSubagents { subagents = newSubagents }
        let newQueued = frame.queued ?? []
        if queued != newQueued { queued = newQueued }
        if contextLabel != frame.context { contextLabel = frame.context }
        let newFullAccess = frame.fullAccess ?? false
        if fullAccess != newFullAccess { fullAccess = newFullAccess }
        let newCanRegenerate = frame.canRegenerate ?? false
        if canRegenerate != newCanRegenerate { canRegenerate = newCanRegenerate }
        let newQuickActions = frame.quickActions ?? []
        if quickActions != newQuickActions { quickActions = newQuickActions }
        let newPaused = frame.paused ?? false
        if paused != newPaused { paused = newPaused }
        // 停止生效 = Mac 不再忙
        if stopping, !busy { stopping = false }
        if tokens != frame.tokens { tokens = frame.tokens }
        if cost != frame.cost { cost = frame.cost }
        // Mac 名字以快照为准（权威、改名也能跟上），并持久化——此前它只在配对
        // 响应里拿过一次，冷启动后为 nil，界面会显示成"未连接 Mac"。
        if let name = frame.desktop, !name.isEmpty, desktopName != name {
            desktopName = name
            defaults.set(name, forKey: "remote.desktopName")
        }
        let target = busy ? "Agent 工作中…" : (desktopOnline ? "已连接" : "Mac 离线")
        if connectionState != target { connectionState = target }
        if let data = try? JSONEncoder().encode(frame.messages) {
            defaults.set(data, forKey: "remote.messages")
        }
        defaults.set(busy, forKey: "remote.busy")
        if queuedOffline, !busy, desktopOnline {
            queuedOffline = false
            connectionState = "已连接"
        }
    }

    // MARK: - 上行（一律 REST push）

    private func pushFrame(_ dict: [String: Any], replace: Bool) {
        guard let sessionKeyB64, let desktopDeviceID,
              let payload = RemoteCrypto.innerFrame(dict, sessionKeyB64: sessionKeyB64) else { return }
        Task { [weak self] in
            guard let self,
                  let body = try? JSONEncoder().encode(PushBody(payload: payload, replace: replace)) else { return }
            let _: PushOK? = try? await self.authedSend(
                "POST", "/remote/push?role=controller&device=\(desktopDeviceID)",
                body: body)
        }
    }

    // MARK: - 对外动作

    func sendPrompt(_ text: String) {
        guard sessionKeyB64 != nil else { return }
        var dict: [String: Any] = ["t": "prompt", "text": text]
        if let selectedSessionID { dict["session"] = selectedSessionID }
        let offline = !desktopOnline
        pushFrame(dict, replace: false)
        queuedOffline = offline
        // 即时回显：不等 Mac 快照，先让指令出现在对话里
        let echo = ChatMessage(id: "echo-\(UUID().uuidString)", role: "user",
                               content: text, reasoning: nil, toolCalls: nil)
        messages.append(echo)
        pendingEcho = echo
        connectionState = offline ? "已排队，Mac 上线后送达" : "Agent 工作中…"
    }

    func sendCancel() {
        pushFrame(["t": "cancel"], replace: false)
        // 桌面 cancel() 会同时解除审批与提问的挂起——本地同步清空，
        // 不必等下一帧（用户点了"停止"就该立刻看到卡片消失）。
        approval = nil
        question = nil
        paused = false
        // Mac 确认（busy=false）之前一直显示"正在停止…"
        stopping = true
    }

    // MARK: - 人工介入 / 进度（上行，一律 REST push）

    /// 审批工具调用。`id` 必须来自快照——Mac 端会校验，防陈旧误批。
    func approve(id: String, decision: RemoteApprovalDecision) {
        pushFrame(["t": "approve", "id": id, "decision": decision.rawValue], replace: false)
        approval = nil
    }

    /// 回答 Agent 的反问。`id` 必须来自快照。
    func answer(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pushFrame(["t": "answer", "id": id, "text": trimmed], replace: false)
        question = nil
    }

    /// 重跑上一条用户消息。
    func regenerate() {
        pushFrame(["t": "regenerate"], replace: false)
    }

    /// 快捷动作（`key` 来自快照 `quickActions`）。
    func quickAction(key: String) {
        pushFrame(["t": "quickAction", "action": key], replace: false)
    }

    /// 移除队列里的某一条（本地乐观移除，Mac 处理后回推快照校正）。
    func removeQueued(id: String) {
        queued.removeAll { $0.id == id }
        pushFrame(["t": "removeQueued", "id": id], replace: false)
    }

    /// 清空排队消息。
    func clearQueued() {
        queued = []
        pushFrame(["t": "clearQueued"], replace: false)
    }

    // MARK: - 会话控制（上行；与桌面面板头部按钮同一语义）

    /// 清空当前对话 = 桌面面板的「新对话」：Mac 会先沉淀记忆摘要再清空。
    func clearConversation() {
        pushFrame(["t": "clear"], replace: false)
        // 本地先清（不等下一帧）：点了"新对话"就该立刻看到空对话
        messages = []
        approval = nil
        question = nil
        plan = []
        subagents = []
        queued = []
        pendingEcho = nil
        canRegenerate = false
        queuedOffline = false
        tokens = nil
        cost = nil
        paused = false
    }

    /// 暂停回合（在下一个检查点前生效，即下一个模型调用/工具执行之前）。
    func pauseTurn() {
        pushFrame(["t": "pause"], replace: false)
        paused = true
    }

    func resumeTurn() {
        pushFrame(["t": "resume"], replace: false)
        paused = false
    }

    /// FULL ACCESS：所有工具免审批（**含任意代码执行**）。风险最高，UI 侧二次确认。
    func setFullAccess(_ on: Bool) {
        pushFrame(["t": "setFullAccess", "flag": on], replace: false)
        fullAccess = on
    }

    // MARK: - 只读信息（按需拉取；页面进入时请求一次 + 下拉刷新）

    func requestCapabilities() { pushFrame(["t": "capabilities"], replace: false) }
    func requestStats() { pushFrame(["t": "stats"], replace: false) }
    func requestTrace() { pushFrame(["t": "trace"], replace: false) }
    func requestModels() { pushFrame(["t": "models"], replace: false) }

    /// 切换服务档案 / 模型（`profile` 传 nil = 只改当前档案的模型）。
    /// 与桌面模型菜单同一落点：写的是 Mac 上的当前档案。
    func selectModel(_ model: String, profile: String? = nil) {
        var dict: [String: Any] = ["t": "setModel", "model": model]
        if let profile { dict["profile"] = profile }
        pushFrame(dict, replace: false)
    }

    /// 请求 Mac 的会话列表（聊天记录）。
    func requestSessions() {
        pushFrame(["t": "sessions"], replace: false)
    }

    /// 让 Mac 新建一个会话并切过去（列表页"+"按钮）。
    /// 乐观切换：不等 Mac 回帧，先进空聊天室（Mac 离线时该指令会在其上线后
    /// 补执行）；Mac 创建后的第一帧快照带 session 字段，据此锁定选中会话。
    func newSession() {
        pendingNewSession = true
        selectedSessionID = nil
        messages = []
        busy = false
        queuedOffline = false
        connectionState = desktopOnline ? "已连接" : "Mac 离线"
        phase = .main
        pushFrame(["t": "newSession"], replace: false)
        scheduleSessionsRefresh()
    }

    /// 写操作（新建/删除/重命名）后等 Mac 处理完再刷列表。
    private func scheduleSessionsRefresh() {
        sessionsRefreshTask?.cancel()
        sessionsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.requestSessions()
        }
    }

    /// 删除会话（列表滑动删除）：本地即时移除 + 通知 Mac 删除落盘。
    func deleteSession(_ id: String) {
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = nil
            messages = []
            pendingNewSession = false
        }
        pushFrame(["t": "deleteSession", "session": id], replace: false)
        scheduleSessionsRefresh()
    }

    /// 重命名会话（列表滑动/长按菜单）：本地即时改 + 通知 Mac 持久化。
    func renameSession(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].label = trimmed
        }
        pushFrame(["t": "renameSession", "session": id, "text": String(trimmed.prefix(100))], replace: false)
        scheduleSessionsRefresh()
    }

    /// 打开某个会话（Mac 侧切换遥控目标并回推该会话快照）。
    func selectSession(_ id: String?) {
        pendingNewSession = false
        selectedSessionID = id
        messages = []
        busy = false
        phase = .main
        var dict: [String: String] = ["t": "select"]
        if let id { dict["session"] = id }
        pushFrame(dict, replace: false)
        requestSync()
    }

    func requestSync() {
        guard sessionKeyB64 != nil else { return }
        pushFrame(["t": "sync"], replace: false)
    }

    /// 扫码登录 Mac：scan（置已扫码）+ confirm（为桌面签发 token）。
    /// 返回桌面名供 UI 确认弹窗展示。
    func qrLoginScanAndConfirm(ticket: String) async throws -> String {
        let token = try await currentToken()
        let scan: QrScanResp = try await API.send(
            "POST", baseURL, "/auth/qr/scan",
            body: try JSONEncoder().encode(QrTicketBody(ticket: ticket)), token: token)
        let _: PushOK = try await API.send(
            "POST", baseURL, "/auth/qr/confirm",
            body: try JSONEncoder().encode(QrTicketBody(ticket: ticket)), token: token)
        return scan.desktopName ?? "Mac"
    }

    /// 拉取 Agent 记忆（画像/事实/摘要；看板打开与下拉刷新时调）。
    func requestMemory() {
        guard sessionKeyB64 != nil else { return }
        pushFrame(["t": "getMemory"], replace: false)
    }

    /// 删除一条事实/摘要（rid 形如 "fact:<uuid>" / "summary:<uuid>"）。
    /// 本地乐观移除，Mac 删除后回推全量记忆帧校正。
    func deleteMemory(rid: String) {
        if let memory {
            var facts = memory.facts
            var summaries = memory.summaries
            facts.removeAll { "fact:\($0.id)" == rid }
            summaries.removeAll { "summary:\($0.id)" == rid }
            self.memory = AgentMemory(t: "memory", profileName: memory.profileName,
                                      profileLanguage: memory.profileLanguage,
                                      profileStyle: memory.profileStyle,
                                      profileCustom: memory.profileCustom,
                                      facts: facts, summaries: summaries)
        }
        pushFrame(["t": "deleteMemory", "id": rid], replace: false)
    }
}
