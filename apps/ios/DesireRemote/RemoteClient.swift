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
            // 恢复持久化的对话记录（杀 App 不丢）
            if let data = defaults.data(forKey: "remote.messages"),
               let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                messages = saved
            }
            busy = defaults.bool(forKey: "remote.busy")
            connectWS()
            startPullLoop()
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

    private func forceRefresh() async throws -> String {
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
        } catch {
            throw sessionExpired()
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

    /// 扫码或粘贴得到二维码内容 → 解析 → 认领。
    func importPairing(_ raw: String) {
        pairError = nil
        guard let data = raw.data(using: .utf8),
              let qr = try? JSONDecoder().decode(PairingQRPayload.self, from: data) else {
            pairError = "二维码内容无法识别"
            return
        }
        // 配对二维码自带服务器地址——用户扫码即显式选择，作为覆盖存下
        saveServerURL(qr.s)
        sessionKeyB64 = qr.k
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let token = try await currentToken()
                let resp: ClaimResp = try await API.send(
                    "POST", baseURL, "/remote/pairing/claim",
                    body: try JSONEncoder().encode(
                        ClaimBody(code: qr.c, controller_name: controllerName)),
                    token: token)
                desktopDeviceID = resp.desktopDeviceId
                desktopName = resp.desktopName
                KeychainStore.set(qr.k, account: "remote.sessionKey")
                KeychainStore.set(resp.desktopDeviceId, account: "remote.desktopID")
                defaults.set(baseURL, forKey: "remote.server")
                hasSavedPairing = true
                messages = []
                busy = false
                phase = .main
                connectWS()
                startPullLoop()
                requestSessions()
            } catch {
                pairError = error.localizedDescription
            }
        }
    }

    /// 回到前台：重连续 transports 并补快照。
    func appForegrounded() {
        guard hasSavedPairing, phase == .main else { return }
        startPullLoop()
        if wsTask == nil { connectWS() }
        requestSync()
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
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["t"] as? String == "memory" {
            memory = try? JSONDecoder().decode(AgentMemory.self, from: data)
            return
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["t"] as? String == "sessions" {
            if let list = root["list"] as? [[String: Any]] {
                sessions = list.compactMap { item in
                    guard let id = item["id"] as? String, let label = item["label"] as? String else { return nil }
                    return RemoteSessionInfo(id: id, label: label,
                                             busy: item["busy"] as? Bool ?? false,
                                             count: item["count"] as? Int ?? 0)
                }
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

    private func pushFrame(_ dict: [String: String], replace: Bool) {
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
        var dict: [String: String] = ["t": "prompt", "text": text]
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
