import AppKit
import Combine
import CoreImage
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// 专用 WebSocket 会话代理：open/close 事件打点（诊断收发问题）。
final class RemoteWSDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        RemoteControlStore.remoteDebug("ws didOpen protocol=\(`protocol` ?? "none")")
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        RemoteControlStore.remoteDebug("ws didClose code=\(closeCode.rawValue)")
        onClose?()
    }
}

/// 远程控制（Mac 被控端）：手机经 api 中继远程对话本机 Agent，
/// **工作仍全部在本地执行**，手机只发指令、看进度、批确认。
///
/// 传输拓扑（服务端可水平扩展，连接无状态，照 Trove im_ws 模式）：
/// - **上行一律 REST** `POST /remote/push`（本端帧 = 快照/回包，E2E 密文，
///   快照带 replace=true：新帧作废收件信箱 pending 旧帧）。
/// - **下行 = WS 频道订阅（express，即时） + `GET /remote/pull`（1s 兜底）**，
///   两条路径按信箱行 id 去重后走同一处理函数。WS 不承载业务帧。
/// - WS 服务端 20s Ping 保活（防 LB 空闲回收）；客户端 20s sendPing 探活，
///   探活失败即触发重连（半开连接 ≤20s 内暴露）。
/// - 连接状态由"最近一次链路活动"（WS 帧/REST 成功）驱动，不再凭
///   `task.resume()` 想当然置 .online。
/// - 配对：设置页生成一次性配对码（10 分钟）+ 本机会话密钥（256 位随机，
///   Keychain 持久），二维码携带 `服务器/码/密钥/设备id`。服务器只见密文。
///   认领后服务器向桌面频道发布 `pairing_claimed` 通知 → 二维码自动收起
///   （Redis 未配置时降级为二维码显示期间的 2s 设备数轮询兜底）。
@MainActor
final class RemoteControlStore: ObservableObject {

    /// 远程链路诊断日志（/tmp/remote_mac_debug.log）——排查链路问题用，
    /// 只在关键事件打点、量极小；后续稳定可移除。
    nonisolated static func remoteDebug(_ line: String) {
        let path = "/tmp/remote_mac_debug.log"
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let text = "[\(stamp)] \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    enum ConnectionState: Equatable {
        case off
        case connecting
        case online
        case error(String)
    }

    struct ActivePairing {
        let code: String
        let expiresAt: Date
        let qrImage: NSImage?
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var connection: ConnectionState = .off
    @Published private(set) var activePairing: ActivePairing?
    @Published private(set) var pairedDevices: [SyncAPIClient.RemotePairedDevice] = []

    private let syncStore: SyncStore
    private let defaults = UserDefaults.standard
    private let enabledKey = "remote.enabled"
    private let sessionKeyAccount = "remote.session-key"
    /// 服务端 base（与 Sync 同源）。
    private var baseURL: String { syncStore.serverBaseURL }

    private var webSocketTask: URLSessionWebSocketTask?
    private let wsDelegate = RemoteWSDelegate()
    private var wsSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var wsPingTask: Task<Void, Never>?
    /// 链路心跳定时器：pull 兜底 + 快照推送 + 状态评估 + 认领检测，1s 一拍。
    private var linkTimer: Timer?

    /// 链路活动（WS 帧到达 / REST 成功）；8s 内有活动 = online。
    private var lastLinkActivity = Date.distantPast
    private var consecutivePollFailures = 0
    private var lastPollError: String?
    private var lastForcedPush = Date.distantPast
    private var lastSnapshotJSON = ""

    /// Sync 账号状态订阅：登出时联动关闭远程（远程鉴权全靠 Sync 的 token）。
    private var authObserver: AnyCancellable?
    private var lastAuthState: SyncStore.AuthState = .signedOut

    init(syncStore: SyncStore) {
        self.syncStore = syncStore
        isEnabled = defaults.bool(forKey: enabledKey)
        lastAuthState = syncStore.authState
        // 账号一登出，远程就彻底不可用了（没有 access token）。此前只把
        // `connection` 静默置成 .off，开关的持久化真值仍是 true——设置页于是
        // 一直显示"远程开启"，用户以为手机还能连上；心跳定时器也在空转。
        authObserver = syncStore.$authState
            .removeDuplicates()
            .sink { [weak self] state in
                Task { @MainActor in self?.authStateChanged(state) }
            }
    }

    /// 只在「已登录 → 登出」这一次转换上联动。启动时 `authState` 初值就是
    /// signedOut（Keychain 尚未读完），不能把它误当成"用户刚登出"。
    private func authStateChanged(_ state: SyncStore.AuthState) {
        let previous = lastAuthState
        lastAuthState = state
        guard case .signedIn = previous, case .signedOut = state else { return }
        shutDownForSignOut()
    }

    /// 登出后的收尾：关开关（持久化）、拆链路、停定时器、清设备与配对码。
    private func shutDownForSignOut() {
        setEnabled(false)      // 内含 teardownLink + 定时器失效 + connection = .off
        pairedDevices = []
        activePairing = nil
        lastSnapshotJSON = ""
    }

    // MARK: - 开关

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        if enabled {
            startLinkLoop()
            connect()
        } else {
            disconnect()
        }
    }

    /// 启动入口（AppState.init 调；内部自判条件，不占启动路径）。
    func startIfEnabled() {
        guard isEnabled else { return }
        startLinkLoop()
        connect()
    }

    private func disconnect() {
        teardownLink()
        linkTimer?.invalidate()
        linkTimer = nil
        lastLinkActivity = .distantPast
        consecutivePollFailures = 0
        connection = .off
    }

    /// 只拆 WS（REST 链路独立于 WS 存活），不动定时器。
    private func teardownLink() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        receiveTask?.cancel()
        receiveTask = nil
        wsPingTask?.cancel()
        wsPingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - 链路心跳循环（1s：pull 兜底 + 快照推送 + 状态评估 + 认领检测）

    private func startLinkLoop() {
        guard linkTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        linkTimer = timer
        tick()
    }

    private func tick() {
        evaluateConnection()
        pollInbox()
        // 快照 15s 强推一拍兜底（平时变化才发）：手机错过一帧也能在半分钟内追平
        pushSnapshot(force: Date().timeIntervalSince(lastForcedPush) > 15)
        claimWatchTick()
    }

    private func noteLinkActivity() {
        lastLinkActivity = Date()
        consecutivePollFailures = 0
        if connection != .online { connection = .online }
    }

    /// 状态诚实化：online = 8s 内有链路活动；连续 3 次 pull 失败才报 error
    /// （单次网络抖动不打脸）。
    private func evaluateConnection() {
        guard isEnabled else {
            if connection != .off { connection = .off }
            return
        }
        guard case .signedIn = syncStore.authState else {
            if connection != .off { connection = .off }
            return
        }
        if consecutivePollFailures >= 3 {
            let message = lastPollError ?? String(localized: "Sync server error")
            if connection != .error(message) { connection = .error(message) }
            return
        }
        let fresh = Date().timeIntervalSince(lastLinkActivity) < 8
        let target: ConnectionState = fresh ? .online : .connecting
        if connection != target { connection = target }
    }

    // MARK: - WS（下行订阅 + 探活；断线 5s 退避重连）

    private func connect() {
        guard isEnabled, case .signedIn = syncStore.authState else { return }
        // **无条件先拆旧连接**：旧 task 残留（死 socket）会吞掉所有重连——
        // 曾经的"existing task 早退"就是重连永久停摆的根因。
        teardownLink()
        Task { @MainActor in
            do {
                let token = try await syncStore.remoteAuthToken()
                guard let url = Self.remoteWSURL(base: self.baseURL, deviceID: self.syncStore.deviceID) else {
                    self.connection = .error(String(localized: "Invalid sync server address"))
                    return
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                // 专用会话（非 .shared）+ 显式禁代理：系统代理会中转 localhost WS
                // 并把服务器写入的下行帧吞在代理侧（下行全灭的根因假设，实测验证）
                let config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = [:]
                let session = URLSession(configuration: config, delegate: self.wsDelegate, delegateQueue: nil)
                self.wsSession = session
                weak let weakSelf = self
                self.wsDelegate.onOpen = {
                    Task { @MainActor in
                        RemoteControlStore.remoteDebug("ws onOpen fired")
                        weakSelf?.noteLinkActivity()
                    }
                }
                self.wsDelegate.onClose = {
                    Task { @MainActor in RemoteControlStore.remoteDebug("ws onClose fired") }
                }
                let task = session.webSocketTask(with: request)
                self.webSocketTask = task
                task.resume()
                Self.remoteDebug("ws resumed url=\(url.absoluteString)")
                self.startPingLoop(task)
                self.startReceiving(task)
            } catch {
                Self.remoteDebug("connect failed: \(error.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }

    /// https → wss / http → ws，拼 `/remote/ws?role=desktop&device=<id>`。
    static func remoteWSURL(base: String, deviceID: String) -> URL? {
        var wsBase = base
        if wsBase.hasPrefix("https://") {
            wsBase = "wss://" + wsBase.dropFirst("https://".count)
        } else if wsBase.hasPrefix("http://") {
            wsBase = "ws://" + wsBase.dropFirst("http://".count)
        }
        return URL(string: "\(wsBase)/remote/ws?role=desktop&device=\(deviceID)")
    }

    private func scheduleReconnect() {
        guard isEnabled, case .signedIn = syncStore.authState, reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            reconnectTask = nil
            self.connect()
        }
    }

    /// 20s sendPing：保活 + 半开连接探活。探活失败 = 链路已死，走统一断开路径
    /// （NAT/对端静默掉线时 receive() 会永远挂着，只有 ping 能暴露）。
    private func startPingLoop(_ task: URLSessionWebSocketTask) {
        wsPingTask?.cancel()
        wsPingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { break }
                await MainActor.run { RemoteControlStore.remoteDebug("ws ping →") }
                task.sendPing { [weak self] error in
                    guard let error else { return }
                    RemoteControlStore.remoteDebug("ws ping failed: \(error.localizedDescription)")
                    Task { @MainActor [weak self] in
                        self?.handleDisconnect(dead: task)
                    }
                }
            }
        }
    }

    /// SyncStore 登录态变化时由设置页/AppState 驱动；未登录即断开。
    func syncAuthDidChange() {
        if case .signedOut = syncStore.authState {
            disconnect()
        } else if case .signedIn = syncStore.authState, isEnabled {
            startLinkLoop()
            connect()
        }
    }

    // MARK: - 收帧（express WS + pull 兜底，单一处理路径）

    /// completion 式接收（re-arm 循环）。async receive() 在本 App 的
    /// MainActor 上下文下曾出现永不返回（下行全灭），回调式无此问题。
    /// 接收循环跑在 **非隔离的 detached 任务**里（与脚本验证环境一致），
    /// 帧处理再跳回 MainActor。曾实测：MainActor 隔离的 receive 永不返回
    /// （下行全灭），非隔离上下文同一 API 正常收帧。
    private func startReceiving(_ task: URLSessionWebSocketTask) {
        receiveTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    break
                }
                let text: String
                switch message {
                case .string(let t): text = t
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                await self?.handleExpressEnvelope(text)
            }
            await self?.handleDisconnect(dead: task)
        }
    }

    private func handleDisconnect(dead: URLSessionWebSocketTask) {
        guard self.webSocketTask === dead || self.webSocketTask == nil else { return }
        self.webSocketTask = nil
        self.receiveTask = nil
        self.wsPingTask?.cancel()
        self.wsPingTask = nil
        Self.remoteDebug("ws lost → schedule reconnect")
        self.scheduleReconnect()
    }

    /// WS express 帧：`{"id":..,"payload":".."}`（业务，与 pull items 同形）
    /// 或 `{"kind":"notify","event":..}`（服务器控制通知，明文）。
    private func handleExpressEnvelope(_ text: String) {
        NSLog("REMOTE-DBG express: %@", String(text.prefix(160)))
        guard let data = text.data(using: .utf8) else { return }
        if let ctrl = try? SyncJSON.makeDecoder().decode(RemoteNotifyEnvelope.self, from: data),
           ctrl.kind == "notify" {
            if ctrl.event == "pairing_claimed" { handlePairingClaimed() }
            return
        }
        if let item = try? SyncJSON.makeDecoder().decode(SyncAPIClient.RemoteInboxPullItem.self, from: data) {
            noteLinkActivity()
            ingestInboxItems([item])
        }
    }

    /// express 与 pull 共用入口：按行 id 去重 → 解密 → 业务帧。
    private func ingestInboxItems(_ items: [SyncAPIClient.RemoteInboxPullItem]) {
        for item in items {
            guard !processedInboxIDs.contains(item.id) else { continue }
            processedInboxIDs.insert(item.id)
            if processedInboxIDs.count > 500 { processedInboxIDs.removeAll() }
            if let inner = Self.decrypt(payloadB64: item.payload, sessionKeyB64: sessionKeyB64) {
                Self.remoteDebug("inner ← \(String(inner.prefix(100)))")
                handleInnerFrame(inner)
            }
        }
    }

    /// 控制通知信封（明文；服务器生成，无业务数据）。
    nonisolated struct RemoteNotifyEnvelope: Codable {
        var kind: String
        var event: String?
    }

    // MARK: - 业务帧（E2E 解密后）：prompt / cancel / sync。

    private func handleInnerFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let inner = try? SyncJSON.makeDecoder().decode(RemoteInnerFrame.self, from: data)
        else { return }
        switch inner.t {
        case "prompt":
            let text = inner.text ?? ""
            guard !text.isEmpty else { return }
            if let sid = inner.session, sid != remoteConversationID {
                remoteConversationID = sid
                openRemoteConversation()
            }
            guard let target = remoteSession else {
                sendInner(["t": "error", "message": String(localized: "No live agent session")])
                return
            }
            target.sendMessage(text, recordHistory: false)
            pushSnapshot(force: true)
        case "select":
            remoteConversationID = inner.session
            openRemoteConversation()
            pushSnapshot(force: true)
        case "sessions":
            sendInnerRaw(sessionsFrame())
        case "newSession":
            // 手机端"+"：新建一条真实对话（落盘、有标题）并在面板中打开。
            // create 只构造值对象——必须再 save()（落盘 + 进内存列表），
            // 否则 sessionsFrame 列表里没有它，手机端永远刷不出新会话。
            guard let app = AppState.live else { return }
            let conversation = app.conversationStore.create(title: "New Conversation")
            app.conversationStore.save(conversation)
            remoteConversationID = conversation.id.uuidString
            openRemoteConversation()
            sendInnerRaw(sessionsFrame())
            pushSnapshot(force: true)
        case "cancel":
            AgentScheduler.shared.deliveryTarget?.cancel()
            pushSnapshot(force: true)
        case "deleteSession":
            // 手机端滑动删除：与桌面历史列表删除同一语义（delete 即移除，
            // 面板正打开的会话不受影响——桌面端行为一致）
            guard let app = AppState.live, let sid = inner.session, let id = UUID(uuidString: sid) else { return }
            app.conversationStore.delete(id)
            if remoteConversationID == sid {
                remoteConversationID = nil
            }
            sendInnerRaw(sessionsFrame())
        case "renameSession":
            // 新标题走内层帧的 text 字段
            guard let app = AppState.live, let sid = inner.session, let id = UUID(uuidString: sid) else { return }
            let title = (inner.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, var conversation = app.conversationStore.conversation(for: id) else { return }
            conversation.title = String(title.prefix(100))
            app.conversationStore.save(conversation)
            sendInnerRaw(sessionsFrame())
        case "sync":
            pushSnapshot(force: true)
        case "getMemory":
            if let json = memoryFrame() { sendInnerRaw(json) }
        case "deleteMemory":
            // id 形如 "fact:<uuid>" / "summary:<uuid>"；走桌面同款删除（记 tombstone）
            guard let rid = inner.id else { return }
            if rid.hasPrefix("fact:"), let uuid = UUID(uuidString: String(rid.dropFirst(5))) {
                AgentMemoryStore.shared.removeFact(uuid)
            } else if rid.hasPrefix("summary:"), let uuid = UUID(uuidString: String(rid.dropFirst(8))) {
                AgentMemoryStore.shared.removeSummary(uuid)
            }
            if let json = memoryFrame() { sendInnerRaw(json) }
        case "approve":
            // 手机端审批。id 必须与当前挂起的审批一致——手机可能停在旧审批上
            // （桌面已批过 A、Agent 又发起 B），不校验就会误批 B。
            guard let id = inner.id, let target = remoteSession,
                  target.pendingApproval?.id.uuidString == id,
                  let decision = inner.decision else {
                pushSnapshot(force: true)
                return
            }
            target.resolveApproval(Self.approvalDecision(decision))
            pushSnapshot(force: true)
        case "answer":
            // askUser 反问：UserPromptCenter 是全局单例，不挂在 session 上。
            guard let text = inner.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let id = inner.id, UserPromptCenter.shared.pending?.id.uuidString != id {
                pushSnapshot(force: true)
                return
            }
            UserPromptCenter.shared.answer(text)
            pushSnapshot(force: true)
        case "regenerate":
            remoteSession?.regenerate()
            pushSnapshot(force: true)
        case "quickAction":
            guard let key = inner.action, let action = AgentQuickAction(wire: key) else { return }
            remoteSession?.performQuickAction(action)
            pushSnapshot(force: true)
        case "removeQueued":
            guard let id = inner.id, let uuid = UUID(uuidString: id) else { return }
            remoteSession?.removeQueued(id: uuid)
            pushSnapshot(force: true)
        case "clearQueued":
            remoteSession?.clearQueuedMessages()
            pushSnapshot(force: true)
        case "clear":
            // 「新对话」：桌面 clear() 会先沉淀 L2 摘要再清空，语义与面板一致。
            remoteSession?.clear()
            pushSnapshot(force: true)
        case "pause":
            remoteSession?.pause()
            pushSnapshot(force: true)
        case "resume":
            remoteSession?.resume()
            pushSnapshot(force: true)
        case "setFullAccess":
            guard let flag = inner.flag, let target = remoteSession else { return }
            target.fullAccess = flag
            pushSnapshot(force: true)
        case "capabilities":
            // 只读回包：Agent 能用的工具（含风险分级）+ 技能库。
            sendInnerRaw(Self.capabilitiesFrame())
        case "stats":
            sendInnerRaw(Self.statsFrame())
        case "trace":
            sendInnerRaw(traceFrame())
        case "models":
            sendInnerRaw(Self.modelsFrame())
        case "setModel":
            applyModelChange(inner)
            pushSnapshot(force: true)
        default:
            break
        }
    }

    /// 序列化 Agent 记忆（画像 + 事实 + 摘要）为手机端可读帧。
    private func memoryFrame() -> String? {
        let archive = AgentMemoryStore.shared.archive
        let facts = archive.facts.prefix(80).map { fact in
            RemoteMemoryFact(
                id: fact.id.uuidString,
                content: String(fact.content.prefix(120)),
                category: fact.category,
                pinned: fact.pinned,
                scope: fact.scope)
        }
        let summaries = archive.summaries.prefix(20).map { summary in
            RemoteMemorySummary(id: summary.id.uuidString, summary: String(summary.summary.prefix(160)))
        }
        let frame = RemoteMemoryFrame(
            t: "memory",
            profileName: archive.profile.name,
            profileLanguage: archive.profile.language,
            profileStyle: archive.profile.style,
            profileCustom: archive.profile.customInstructions,
            facts: Array(facts),
            summaries: Array(summaries))
        guard let data = try? SyncJSON.makeEncoder().encode(frame) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 上行（一律 REST push）

    /// lane: "snapshot" = 快照 lane（replace 只清同 lane，不误删 sessions 回包）。
    private func pushPayload(_ payload: String, lane: String, replace: Bool) {
        Task { @MainActor [weak self] in
            guard let self, case .signedIn = self.syncStore.authState else { return }
            guard let token = try? await self.syncStore.remoteAuthToken() else { return }
            do {
                try await SyncAPIClient.remotePush(
                    baseURL: self.baseURL, accessToken: token, deviceID: self.syncStore.deviceID,
                    role: "desktop", lane: lane, payload: payload, replace: replace)
                self.noteLinkActivity()
            } catch {
                Self.remoteDebug("push failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendInnerRaw(_ json: String) {
        guard let payload = Self.encrypt(data: Data(json.utf8), sessionKeyB64: sessionKeyB64) else { return }
        pushPayload(payload, lane: "", replace: false)
    }

    private func sendInner(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        sendInnerRaw(json)
    }

    // MARK: - 快照推送（1s 一拍、变化才发；15s 强推兜底）

    struct RemoteSnapshotMessage: Codable {
        let id: String
        let role: String
        let content: String?
        let reasoning: String?
        let toolCalls: [String]?
        /// 与 toolCalls 一一对应的参数摘要（各截 160 字符），手机端展开显示
        var toolArgs: [String]? = nil
    }

    struct RemoteSnapshotFrame: Codable {
        let t: String
        let messages: [RemoteSnapshotMessage]
        let busy: Bool
        /// 当前遥控的 Mac 会话 id（手机端会话列表高亮用）
        let session: String?
        /// Agent 状态行（手机看板/状态胶囊）：当前模型
        var model: String? = nil
        /// 上下文占用%（与面板状态行同口径 contextFraction）
        var contextPercent: Int? = nil
        /// 排队消息条数
        var queueCount: Int? = nil
        /// busy 时当前回合已用时（秒）
        var elapsed: Int? = nil

        // MARK: 人工介入 / 进度（0.1.x 远程对齐桌面面板；全部可选，旧客户端忽略）

        /// 待审批的工具调用（Agent 挂起等 Allow Once / Always Allow / Deny）
        var approval: ApprovalPayload? = nil
        /// Agent 的反问（askUser 挂起等回答；全局单例，不挂 session）
        var question: QuestionPayload? = nil
        /// updatePlan 维护的任务清单
        var plan: [PlanStepPayload]? = nil
        /// spawnSubagent / crew 子代理实时进度
        var subagents: [SubagentPayload]? = nil
        /// 回合进行中输入、排队待发的消息（可逐条移除）
        var queued: [QueuedPayload]? = nil
        /// Agent 将要操作的目标页（"Title — host"）
        var context: String? = nil
        /// FULL ACCESS：所有工具免审批（手机据此解释"为何不弹审批"）
        var fullAccess: Bool? = nil
        /// 上一轮已结束且末条是 assistant → 可重新生成
        var canRegenerate: Bool? = nil
        /// 快捷动作（Mac 为唯一文案来源，避免两端硬编码漂移）
        var quickActions: [QuickActionPayload]? = nil
        /// 回合被暂停（pause 后、resume 前；面板头部同款按钮的状态）
        var paused: Bool? = nil
        /// 本对话累计 token（与桌面状态行同一套 AgentUsage）
        var tokens: Int? = nil
        /// 本对话累计成本（未填单价时为 nil——**不显示 0**，与桌面同口径）
        var cost: String? = nil
        /// 本机（Mac）显示名。手机端此前只在配对响应里拿到过一次、且没持久化，
        /// 冷启动后名字为 nil 就会被渲染成"未连接 Mac"，与真实的连接状态互相
        /// 矛盾。随快照持续下发后，手机始终有权威名字（Mac 改名也能跟上）。
        var desktop: String? = nil

        struct ApprovalPayload: Codable {
            var id: String
            var tool: String
            /// readonly | sideEffect | dangerous
            var risk: String
            var summary: String
            /// dangerous 档不提供"始终允许"
            var dangerous: Bool
        }

        struct QuestionPayload: Codable {
            var id: String
            var text: String
            /// 兜底超时（秒），供手机端提示
            var timeout: Int
        }

        struct PlanStepPayload: Codable {
            var content: String
            /// pending | in_progress | done
            var status: String
        }

        struct SubagentPayload: Codable {
            var label: String
            var step: Int
            var maxSteps: Int
            var tool: String?
        }

        struct QueuedPayload: Codable {
            var id: String
            var text: String
        }

        struct QuickActionPayload: Codable {
            var key: String
            var title: String
            var icon: String
        }
    }

    private func pushSnapshot(force: Bool) {
        guard isEnabled, case .signedIn = syncStore.authState else { return }
        if force { lastForcedPush = Date() }
        // 无活动会话也要回空快照：手机端"已连接、空闲"是合法状态，静默会让对端以为信道死了
        let session = remoteSession
        let messages = (session?.messages.suffix(100) ?? []).map { message -> RemoteSnapshotMessage in
            RemoteSnapshotMessage(
                id: message.id.uuidString,
                role: message.role.rawValue,
                content: message.content.map { String($0.prefix(2000)) },
                reasoning: message.reasoning.map { String($0.prefix(600)) },
                toolCalls: message.toolCalls.map { $0.map(\.function.name) },
                toolArgs: message.toolCalls.map { $0.map { String($0.function.arguments.prefix(160)) } })
        }
        let elapsedSeconds = session?.processingStartedAt.map {
            max(0, Int(Date().timeIntervalSince($0)))
        }
        let frame = RemoteSnapshotFrame(
            t: "snapshot", messages: Array(messages),
            busy: session?.isProcessing ?? false,
            session: remoteConversationID,
            model: AppState.live?.aiPreference.model,
            contextPercent: session.map { Int(($0.contextFraction * 100).rounded()) },
            queueCount: session.map { $0.queuedMessages.count },
            elapsed: (session?.isProcessing ?? false) ? elapsedSeconds : nil,
            approval: Self.approvalPayload(session?.pendingApproval),
            question: Self.questionPayload(UserPromptCenter.shared.pending),
            plan: Self.planPayload(),
            subagents: Self.subagentPayloads(session?.runningSubagents ?? []),
            queued: Self.queuedPayloads(session?.queuedMessages ?? []),
            context: session?.contextLabel,
            fullAccess: session?.fullAccess,
            canRegenerate: Self.remoteCanRegenerate(session),
            quickActions: Self.quickActionPayloads(),
            paused: session?.isPaused ?? false,
            tokens: Self.remoteTokenCount(session),
            cost: session?.conversationUsage.formattedUSD,
            desktop: Host.current().localizedName ?? "Mac")
        guard let data = try? SyncJSON.makeEncoder().encode(frame) else { return }
        let fingerprint = String(data: data, encoding: .utf8) ?? ""
        if !force && fingerprint == lastSnapshotJSON { return }
        lastSnapshotJSON = fingerprint
        guard let payload = Self.encrypt(data: data, sessionKeyB64: sessionKeyB64) else { return }
        Self.remoteDebug("snapshot push (\(frame.messages.count) msgs, busy=\(frame.busy), force=\(force))")
        pushPayload(payload, lane: "snapshot", replace: true)
    }

    // MARK: - 快照：人工介入 / 进度载荷组装（有界截断，保持帧小）

    /// 待审批工具调用 → 载荷。`dangerous` 档供手机禁用"始终允许"。
    private static func approvalPayload(
        _ approval: PendingToolApproval?
    ) -> RemoteSnapshotFrame.ApprovalPayload? {
        guard let approval else { return nil }
        let risk: String
        switch approval.risk {
        case .readonly: risk = "readonly"
        case .sideEffect: risk = "sideEffect"
        case .dangerous: risk = "dangerous"
        }
        return RemoteSnapshotFrame.ApprovalPayload(
            id: approval.id.uuidString,
            tool: approval.toolCall.function.name,
            risk: risk,
            summary: String(approval.argumentsSummary.prefix(240)),
            dangerous: approval.risk == .dangerous)
    }

    /// Agent 反问（`UserPromptCenter` 是全局单例，不挂 session）→ 载荷。
    private static func questionPayload(
        _ pending: PendingUserQuestion?
    ) -> RemoteSnapshotFrame.QuestionPayload? {
        guard let pending else { return nil }
        return RemoteSnapshotFrame.QuestionPayload(
            id: pending.id.uuidString,
            text: String(pending.question.prefix(800)),
            timeout: Int(UserPromptCenter.answerTimeout))
    }

    /// `updatePlan` 清单：最多 20 步、每步截 120。
    private static func planPayload() -> [RemoteSnapshotFrame.PlanStepPayload]? {
        let steps = AgentPlanStore.shared.steps
        guard !steps.isEmpty else { return nil }
        return steps.prefix(20).map {
            RemoteSnapshotFrame.PlanStepPayload(
                content: String($0.content.prefix(120)), status: $0.status)
        }
    }

    /// 子代理进度：最多 4 条、label 截 80。
    private static func subagentPayloads(
        _ runs: [AgentSessionStore.SubagentProgress]
    ) -> [RemoteSnapshotFrame.SubagentPayload]? {
        guard !runs.isEmpty else { return nil }
        return runs.prefix(4).map {
            RemoteSnapshotFrame.SubagentPayload(
                label: String($0.label.prefix(80)), step: $0.step,
                maxSteps: $0.maxSteps, tool: $0.currentTool)
        }
    }

    /// 排队消息：最多 8 条、每条截 120（手机端可逐条移除）。
    private static func queuedPayloads(
        _ items: [AgentSessionStore.QueuedMessage]
    ) -> [RemoteSnapshotFrame.QueuedPayload]? {
        guard !items.isEmpty else { return nil }
        return items.prefix(8).map {
            RemoteSnapshotFrame.QueuedPayload(
                id: $0.id.uuidString, text: String($0.text.prefix(120)))
        }
    }

    /// 快捷动作（Mac 为唯一文案来源，两端不硬编码）。
    private static func quickActionPayloads() -> [RemoteSnapshotFrame.QuickActionPayload]? {
        let list = AgentQuickAction.allCases.map {
            RemoteSnapshotFrame.QuickActionPayload(key: $0.wire, title: $0.title, icon: $0.icon)
        }
        return list.isEmpty ? nil : list
    }

    /// 与桌面 `AgentPanel.canRegenerate` 同口径：回合结束、非提问态、末条是 assistant。
    private static func remoteCanRegenerate(_ session: AgentSessionStore?) -> Bool {
        guard let session, !session.isProcessing, !session.awaitingQuestion else { return false }
        return session.messages.last?.role == .assistant
    }

    /// 手机端审批决定的线路值 → `ApprovalDecision`（未知值按最保守的"拒绝"处理）。
    private static func approvalDecision(_ wire: String) -> ApprovalDecision {
        switch wire {
        case "allowOnce": return .allowOnce
        case "alwaysAllow": return .alwaysAllow
        default: return .deny
        }
    }

    /// 本对话累计 token（0 → nil：手机端不显示 "0 token" 这种噪音）。
    private static func remoteTokenCount(_ session: AgentSessionStore?) -> Int? {
        let total = session?.conversationUsage.totalTokens ?? 0
        return total > 0 ? total : nil
    }

    // MARK: - 只读信息帧（能力 / 统计 / 轨迹 / 模型）
    //
    // 这四类都是**手机主动请求、Mac 一次性回包**（走 controller lane 的普通
    // 回包，不进每秒快照——数据量比状态大，按需取才合理，也与 sessions 列表
    // 的既有约定一致）。

    /// 组装内层回包 JSON（编码失败给一个显式错误帧，别让手机端干等）。
    private static func encodeInfoFrame(_ dict: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"t\":\"error\",\"message\":\"encode failed\"}"
    }

    private static func remoteRiskName(_ risk: ToolRisk) -> String {
        switch risk {
        case .readonly: return "readonly"
        case .sideEffect: return "sideEffect"
        case .dangerous: return "dangerous"
        }
    }

    /// 能力与工具：Agent 可调用的全部工具（含风险分级）+ 技能库。
    /// 与桌面「能力」页同源（`AgentCapabilitiesView`）。
    private static func capabilitiesFrame() -> String {
        let defs = BrowserToolProvider.toolDefs + MCPStore.shared.toolDefs
        let tools: [[String: Any]] = defs.map { def in
            [
                "name": def.function.name,
                "description": String(def.function.description.prefix(300)),
                "risk": remoteRiskName(ToolRisk.classify(def.function.name)),
            ]
        }
        let skills: [[String: String]] = SkillStore.shared.skills.map {
            ["name": $0.name, "description": String($0.description.prefix(300))]
        }
        return encodeInfoFrame(["t": "capabilities", "tools": tools, "skills": skills])
    }

    /// 跨会话用量统计（与桌面「用量」页、桥 `/agent/stats` 同一份口径）。
    private static func statsFrame() -> String {
        let store = ConversationStore()
        let preference = AppState.live?.aiPreference
        let stats = UsageStats.derive(from: store.conversations,
                                      price: { preference?.usagePrice(for: $0) })
        var payload: [String: Any] = [
            "t": "stats",
            "totalTokens": stats.totalTokens,
            "promptTokens": stats.promptTokens,
            "completionTokens": stats.completionTokens,
            "turns": stats.turns,
            "conversations": stats.conversations,
            "unpricedTokens": stats.unpricedTokens,
            "longestConversationSeconds": (stats.longestConversation * 10).rounded() / 10,
            "currentStreak": stats.currentStreak,
            "longestStreak": stats.longestStreak,
            "models": stats.models.map { model -> [String: Any] in
                ["model": model.id, "tokens": model.tokens,
                 "promptTokens": model.promptTokens,
                 "completionTokens": model.completionTokens,
                 "cost": model.cost as Any]
            },
        ]
        payload["cost"] = stats.cost as Any
        payload["peakDayTokens"] = stats.peakDayTokens
        return encodeInfoFrame(payload)
    }

    /// 当前会话的轨迹（Thought → Action → Observation，按回合）+ 聚合统计。
    /// 只回最近 20 个回合、每回合只留手机要展示的字段——帧能小则小。
    private func traceFrame() -> String {
        guard let app = AppState.live,
              let sid = remoteConversationID ?? remoteSession?.conversationId?.uuidString,
              let id = UUID(uuidString: sid),
              let conversation = app.conversationStore.conversation(for: id) else {
            return Self.encodeInfoFrame(["t": "trace", "turns": [], "stats": [:]])
        }
        let preference = app.aiPreference
        let turns = AgentTrace.turns(of: conversation, price: { preference.usagePrice(for: $0) })
        let stats = AgentTrace.stats(of: turns)
        let trimmed: [[String: Any]] = turns.suffix(20).map { turn in
            var out: [String: Any] = [
                "turn": turn["turn"] as? Int ?? 0,
                "goal": String((turn["goal"] as? String ?? "").prefix(240)),
                "toolCalls": turn["toolCalls"] as? Int ?? 0,
            ]
            if let answer = turn["answer"] as? String, !answer.isEmpty {
                out["answer"] = String(answer.prefix(400))
            }
            if let started = turn["startedAt"] as? String { out["startedAt"] = started }
            if let tokens = turn["tokens"] { out["tokens"] = tokens }
            if let cost = turn["cost"] { out["cost"] = cost }
            if let model = turn["model"] { out["model"] = model }
            out["steps"] = (turn["steps"] as? [[String: Any]] ?? []).map { step -> [String: Any] in
                var s: [String: Any] = ["action": step["action"] as? String ?? "?"]
                if let ms = step["ms"] { s["ms"] = ms }
                if let denied = step["denied"] as? Bool, denied { s["denied"] = true }
                if let threw = step["threwError"] as? Bool, threw { s["failed"] = true }
                return s
            }
            return out
        }
        return Self.encodeInfoFrame(["t": "trace", "turns": trimmed, "stats": stats])
    }

    /// 可用的模型服务档案 + 当前档案的候选模型（手机「模型」页）。
    private static func modelsFrame() -> String {
        guard let preference = AppState.live?.aiPreference else {
            return encodeInfoFrame(["t": "models", "profiles": [], "models": [], "active": ""])
        }
        let profiles: [[String: String]] = preference.profiles.map {
            ["id": $0.id.uuidString, "name": $0.name, "model": $0.model]
        }
        return encodeInfoFrame([
            "t": "models",
            "profiles": profiles,
            "active": preference.activeProfile?.id.uuidString ?? "",
            "models": preference.activeProfile?.modelList ?? [],
        ])
    }

    /// 手机切换服务档案 / 模型（与桌面模型菜单同一落点：改当前档案）。
    private func applyModelChange(_ inner: RemoteInnerFrame) {
        guard let preference = AppState.live?.aiPreference else { return }
        if let pid = inner.profile, let uuid = UUID(uuidString: pid) {
            preference.activeProfileID = uuid
        }
        if let model = inner.model, !model.isEmpty {
            preference.model = model
        }
    }

    /// pull 兜底（1s 一拍）：取走桌面信箱帧；服务器顺带盖在线戳。
    private var pollInFlight = false
    /// 已处理过的帧 id（express 先到时，兜底 pull 的同 id 行直接跳过）
    private var processedInboxIDs: Set<Int64> = []
    private func pollInbox() {
        guard isEnabled, case .signedIn = syncStore.authState, !pollInFlight else { return }
        pollInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pollInFlight = false }
            guard let token = try? await self.syncStore.remoteAuthToken() else { return }
            do {
                let resp = try await SyncAPIClient.remotePullInbox(
                    baseURL: self.baseURL, accessToken: token,
                    deviceID: self.syncStore.deviceID, role: "desktop")
                self.noteLinkActivity()
                self.ingestInboxItems(resp.items)
            } catch {
                self.consecutivePollFailures += 1
                self.lastPollError = error.localizedDescription
                Self.remoteDebug("pull failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 配对

    struct RemotePairingQR: Codable {
        var v: Int
        var s: String
        var c: String
        var k: String
        var d: String
    }

    /// 生成配对码 + 二维码（会话密钥首次生成后存 Keychain，长期复用）。
    func startPairing() {
        Task { @MainActor in
            do {
                let token = try await syncStore.remoteAuthToken()
                // 先对齐已配对数（认领检测的基线），再签发新码
                if let existing = try? await SyncAPIClient.remoteDevices(
                    baseURL: baseURL, accessToken: token).devices {
                    pairedDevices = existing
                }
                deviceCountAtPairingStart = pairedDevices.count
                let deviceName = Host.current().localizedName ?? "Mac"
                let resp = try await SyncAPIClient.remotePairingStart(
                    baseURL: baseURL, accessToken: token,
                    deviceID: syncStore.deviceID, deviceName: deviceName)
                let key = try currentOrCreateSessionKey()
                let qrPayload = RemotePairingQR(
                    v: 1, s: baseURL, c: resp.code, k: key, d: syncStore.deviceID)
                let qrData = try SyncJSON.makeEncoder().encode(qrPayload)
                pairingStartedAt = Date()
                activePairing = ActivePairing(
                    code: resp.code,
                    expiresAt: Date().addingTimeInterval(600),
                    qrImage: Self.makeQR(from: String(data: qrData, encoding: .utf8) ?? ""))
                refreshDevices()
            } catch {
                connection = .error(error.localizedDescription)
            }
        }
    }

    /// 登录二维码要顺带携带的配对信息（c/k/d）；远程未开启或未登录时返回 nil
    /// —— 那样手机只完成「登录本机」，仍需单独扫码配对。
    ///
    /// 起因：会话密钥（`k`）此前**只存在于配对码里**，扫码登录只解决账号登录，
    /// 于是手机扫完登录码会一直停在配对页（用户实测反馈）。
    func pairingPayloadForLoginQR() async -> [String: Any]? {
        guard isEnabled, case .signedIn = syncStore.authState else { return nil }
        do {
            let token = try await syncStore.remoteAuthToken()
            let resp = try await SyncAPIClient.remotePairingStart(
                baseURL: baseURL, accessToken: token,
                deviceID: syncStore.deviceID,
                deviceName: Host.current().localizedName ?? "Mac")
            let key = try currentOrCreateSessionKey()
            return ["c": resp.code, "k": key, "d": syncStore.deviceID]
        } catch {
            Self.remoteDebug("pairing payload for login QR failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 服务器向桌面频道发布的认领通知（express）——二维码即刻收起。
    private func handlePairingClaimed() {
        guard activePairing != nil else { return }
        Self.remoteDebug("pairing claimed (notify) → clear QR")
        clearActivePairing()
        refreshDevices()
    }

    private func clearActivePairing() {
        activePairing = nil
        pairingStartedAt = nil
    }

    /// 认领检测兜底（Redis 未配置时 notify 收不到）：二维码显示期间每 2s
    /// 刷一次设备列表，数量增加 = 已认领；过期自动收起。
    private var pairingStartedAt: Date?
    private var deviceCountAtPairingStart = 0
    private var claimWatchCounter = 0
    private func claimWatchTick() {
        guard let pairing = activePairing else {
            claimWatchCounter = 0
            return
        }
        if pairing.expiresAt.timeIntervalSinceNow < -5 {
            clearActivePairing()
            return
        }
        claimWatchCounter += 1
        guard claimWatchCounter % 2 == 0 else { return }
        Task { @MainActor [weak self] in
            guard let self, let token = try? await self.syncStore.remoteAuthToken() else { return }
            guard let devices = try? await SyncAPIClient.remoteDevices(
                baseURL: self.baseURL, accessToken: token).devices else { return }
            self.pairedDevices = devices
            if self.activePairing != nil,
               devices.count > self.deviceCountAtPairingStart {
                Self.remoteDebug("pairing claimed (poll) → clear QR")
                self.clearActivePairing()
            }
        }
    }

    func refreshDevices() {
        guard case .signedIn = syncStore.authState else { return }
        Task { @MainActor [weak self] in
            guard let self, let token = try? await self.syncStore.remoteAuthToken() else { return }
            guard let devices = try? await SyncAPIClient.remoteDevices(
                baseURL: self.baseURL, accessToken: token).devices else { return }
            self.pairedDevices = devices
        }
    }

    func revoke(deviceID: String, controllerName: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = try await self.syncStore.remoteAuthToken()
                try await SyncAPIClient.remotePairingRevoke(
                    baseURL: self.baseURL, accessToken: token,
                    deviceID: deviceID, controllerName: controllerName)
                self.refreshDevices()
            } catch {
                self.connection = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - 桥（E2E/自动化）辅助

    /// 桥（E2E/自动化）读取当前配对码与密钥。**仅限本地自动化桥**，
    /// 等价于把二维码内容给到本机脚本——不得经任何网络端点外暴。
    struct PairingSecrets {
        let code: String
        let sessionKeyB64: String
    }

    var pairingSecrets: PairingSecrets? {
        guard let activePairing, let key = sessionKeyB64 else { return nil }
        return PairingSecrets(code: activePairing.code, sessionKeyB64: key)
    }

    var connectionForBridge: String {
        switch connection {
        case .off: return "off"
        case .connecting: return "connecting"
        case .online: return "online"
        case .error(let message): return "error: \(message)"
        }
    }

    // MARK: - 手机遥控的目标会话

    /// 手机端选中的**对话** id（ConversationStore 的对话；nil = 最新一条）
    private var remoteConversationID: String?
    /// 远程新建的会话强引用——AgentScheduler 里是弱引用，不持有会立即释放，
    /// 表现为"列表闪烁/新建无效"。
    private var remoteCreatedSessions: [AgentSessionStore] = []

    /// 远程对话的执行者 = Mac 当前活跃的 Agent 会话（面板）；选中的对话
    /// 会在它里面打开——**远程发消息与本地发消息完全等效**。
    private var remoteSession: AgentSessionStore? {
        AgentScheduler.shared.deliveryTarget
    }

    /// 在活跃会话里打开手机选中的对话（面板同步切换到该对话）。
    private func openRemoteConversation() {
        guard let remoteConversationID, let id = UUID(uuidString: remoteConversationID) else { return }
        remoteSession?.loadConversation(id)
    }

    /// 会话列表 = **用户的真实对话**（ConversationStore，有标题/会持久化），
    /// 不再是窗口会话——远程 App 就是本地 Agent 对话的镜像。
    private func sessionsFrame() -> String {
        guard let app = AppState.live else {
            return "{\"t\":\"sessions\",\"list\":[]}"
        }
        let busy = remoteSession?.isProcessing ?? false
        let list = app.conversationStore.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(50)
            .map { conversation -> [String: Any] in
                ["id": conversation.id.uuidString,
                 "label": conversation.title,
                 "busy": busy && conversation.id.uuidString == remoteConversationID,
                 "count": conversation.messages.count,
                 "date": conversation.updatedAt.timeIntervalSince1970]
            }
        let dict: [String: Any] = ["t": "sessions", "list": Array(list)]
        return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"t\":\"sessions\",\"list\":[]}"
    }

    // MARK: - E2E 会话密钥（Keychain 持久；二维码携带）

    private var cachedSessionKey: String?

    private var sessionKeyB64: String? {
        if let cachedSessionKey { return cachedSessionKey }
        let key = keychainRead(sessionKeyAccount)
        cachedSessionKey = key
        return key
    }

    private func currentOrCreateSessionKey() throws -> String {
        if let existing = sessionKeyB64 { return existing }
        let key = Self.randomKeyB64()
        keychainWrite(key, account: sessionKeyAccount)
        cachedSessionKey = key
        return key
    }

    nonisolated static func randomKeyB64() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 退化路径：系统 CSPRNG 失败极罕见；用 CryptoKit 随机
            let key = SymmetricKey(size: .bits256)
            return Data(key.withUnsafeBytes { Data($0) }).base64EncodedString()
        }
        return Data(bytes).base64EncodedString()
    }

    /// AES-256-GCM。密钥 = 会话密钥原文 32 字节；随机 nonce；combined → base64。
    nonisolated static func encrypt(dict: [String: Any], sessionKeyB64: String?) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return encrypt(data: json, sessionKeyB64: sessionKeyB64)
    }

    nonisolated static func encrypt(data: Data, sessionKeyB64: String?) -> String? {
        guard let sessionKeyB64,
              let keyData = Data(base64Encoded: sessionKeyB64),
              keyData.count == 32 else { return nil }
        let key = SymmetricKey(data: keyData)
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else { return nil }
        return sealed.base64EncodedString()
    }

    nonisolated static func decrypt(payloadB64: String, sessionKeyB64: String?) -> String? {
        guard let sessionKeyB64,
              let keyData = Data(base64Encoded: sessionKeyB64), keyData.count == 32,
              let combined = Data(base64Encoded: payloadB64) else { return nil }
        let key = SymmetricKey(data: keyData)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - QR

    nonisolated static func makeQR(from text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
    }

    // MARK: - Keychain（范式同 SyncStore；非交互读）

    private func keychainRead(_ account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "me.siwi.Desire",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ value: String, account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "me.siwi.Desire",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// 业务帧（E2E 内层）。t = snapshot/prompt/cancel/sync/error。
nonisolated struct RemoteInnerFrame: Codable {
    var t: String
    var text: String?
    var message: String?
    var body: String?
    var session: String?
    /// 记忆条目 id（"fact:<uuid>" / "summary:<uuid>"，deleteMemory 用）；
    /// 亦作 approve / answer / removeQueued 的目标 id（approval / question / queued 行 id）
    var id: String?
    /// 审批决定（approve 用）：allowOnce | alwaysAllow | deny
    var decision: String?
    /// 快捷动作 key（quickAction 用，见 AgentQuickAction.wire）
    var action: String?
    /// 布尔开关负载（setFullAccess 用）
    var flag: Bool?
    /// 模型 id（setModel 用）
    var model: String?
    /// 服务档案 id（setModel 用，切换服务；nil = 只改当前档案的模型）
    var profile: String?
}

// MARK: - 记忆帧（手机拉取 Agent 记忆：画像 / 事实 / 摘要）

nonisolated struct RemoteMemoryFact: Codable {
    var id: String
    var content: String
    var category: String
    var pinned: Bool
    var scope: String
}

nonisolated struct RemoteMemorySummary: Codable {
    var id: String
    var summary: String
}

/// `t = "memory"`。摘要截 160 字符、事实截 120——列表可读即可，全文在桌面端。
nonisolated struct RemoteMemoryFrame: Codable {
    var t: String
    var profileName: String
    var profileLanguage: String
    var profileStyle: String
    var profileCustom: String
    var facts: [RemoteMemoryFact]
    var summaries: [RemoteMemorySummary]
}
