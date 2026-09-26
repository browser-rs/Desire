import AppKit
import Combine
import CoreImage
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// 远程控制（Mac 被控端）：手机经 api 中继与本机建立 E2E 加密通道，
/// 远程对话 Agent——**工作仍全部在本地执行**，手机只发指令、看进度、批确认。
///
/// - 配对：设置页生成一次性配对码（10 分钟）+ 本机会话密钥（256 位随机，
///   Keychain 持久），二维码携带 `服务器/码/密钥/设备id`。服务器只见密文。
/// - 信道：WebSocket 出站连中继（无需公网入站），业务载荷 AES-256-GCM 密文。
/// - 桥接：prompt → AgentSessionStore.sendMessage（与桥 /agent/send 同路径）；
///   快照（消息 suffix(20) + busy）1 秒一拍、变化才发——手机端重连先发 sync 补快照。
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

@MainActor
final class RemoteControlStore: ObservableObject {

    /// 远程链路诊断日志（/tmp/remote_mac_debug.log）——排查下行投递问题用，
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
    private var snapshotTimer: Timer?
    private var lastSnapshotJSON = ""
    private var refreshDevicesTask: Task<Void, Never>?

    init(syncStore: SyncStore) {
        self.syncStore = syncStore
        isEnabled = defaults.bool(forKey: enabledKey)
    }

    // MARK: - 开关

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        if enabled {
            connect()
        } else {
            disconnect()
        }
    }

    /// 启动入口（AppState.init 调；内部自判条件，不占启动路径）。
    func startIfEnabled() {
        guard isEnabled else { return }
        connect()
    }

    private func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        connection = .off
    }

    // MARK: - 连接（出站 WS；断线 5s 退避重连）

    private func connect() {
        guard isEnabled, case .signedIn = syncStore.authState else {
            connection = .off
            return
        }
        // **无条件先拆旧连接**：旧 task 残留（死 socket）会吞掉所有重连——
        // 曾经的"existing task 早退"就是重连永久停摆的根因。
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        connection = .connecting
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
                self.wsDelegate.onOpen = {
                    Task { @MainActor in RemoteControlStore.remoteDebug("ws onOpen fired") }
                }
                self.wsDelegate.onClose = {
                    Task { @MainActor in RemoteControlStore.remoteDebug("ws onClose fired") }
                }
                let task = session.webSocketTask(with: request)
                self.webSocketTask = task
                task.resume()
                Self.remoteDebug("ws resumed url=\(url.absoluteString)")
                self.connection = .online
                self.startSnapshotLoop()
                self.startReceiving(task)
            } catch {
                Self.remoteDebug("connect failed: \(error.localizedDescription)")
                self.connection = .error(error.localizedDescription)
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

    /// SyncStore 登录态变化时由设置页/AppState 驱动；未登录即断开。
    func syncAuthDidChange() {
        if case .signedOut = syncStore.authState {
            disconnect()
        }
    }

    // MARK: - 收发

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
                await self?.handleTransportFrame(text)
            }
            await self?.handleDisconnect(dead: task)
        }
    }

    private func handleDisconnect(dead: URLSessionWebSocketTask) {
        guard self.webSocketTask === dead || self.webSocketTask == nil else { return }
        self.webSocketTask = nil
        self.receiveTask = nil
        self.snapshotTimer?.invalidate()
        self.snapshotTimer = nil
        guard self.isEnabled, case .signedIn = self.syncStore.authState else {
            self.connection = .off
            return
        }
        self.connection = .error(String(localized: "Sync server error"))
        Self.remoteDebug("ws lost → schedule reconnect")
        self.scheduleReconnect()
    }

    /// 传输帧（服务器可见）：inbox / pong；route 业务载荷已在上层路由。
    private func handleTransportFrame(_ text: String) {
        NSLog("REMOTE-DBG transport: %@", String(text.prefix(160)))
        guard let data = text.data(using: .utf8),
              let frame = try? SyncJSON.makeDecoder().decode(RemoteTransportFrame.self, from: data)
        else { return }
        switch frame.kind {
        case "inbox":
            for item in frame.items ?? [] {
                if let inner = Self.decrypt(payloadB64: item.payload, sessionKeyB64: sessionKeyB64) {
                    handleInnerFrame(inner)
                }
                sendTransport(["kind": "ack", "ids": [item.id]])
            }
        case "route":
            // 中继转发的控制器业务帧（密文）——解密后进业务处理
            if let payload = frame.payload,
               let inner = Self.decrypt(payloadB64: payload, sessionKeyB64: sessionKeyB64) {
                handleInnerFrame(inner)
            }
        default:
            break
        }
    }

    /// 业务帧（E2E 解密后）：prompt / cancel / sync。
    private func handleInnerFrame(_ text: String) {
        Self.remoteDebug("inner ← \(String(text.prefix(120)))")
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
            // 手机端"+"：新建一条真实对话（落盘、有标题）并在面板中打开
            guard let app = AppState.live else { return }
            let conversation = app.conversationStore.create(title: "New Conversation")
            remoteConversationID = conversation.id.uuidString
            openRemoteConversation()
            sendInnerRaw(sessionsFrame())
            pushSnapshot(force: true)
        case "cancel":
            AgentScheduler.shared.deliveryTarget?.cancel()
            pushSnapshot(force: true)
        case "sync":
            pushSnapshot(force: true)
        default:
            break
        }
    }

    private func sendTransport(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    private func sendInnerRaw(_ json: String) {
        guard let data = json.data(using: .utf8),
              let payload = Self.encrypt(data: data, sessionKeyB64: sessionKeyB64) else { return }
        sendTransport(["kind": "route", "payload": payload])
    }

    private func sendInner(_ dict: [String: Any]) {
        guard let payload = Self.encrypt(dict: dict, sessionKeyB64: sessionKeyB64) else { return }
        sendTransport(["kind": "route", "payload": payload])
    }

    // MARK: - 快照推送（1 秒一拍；变化才发）

    private func startSnapshotLoop() {
        snapshotTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pushSnapshot(force: false)
                self?.pollInbox()
            }
        }
        snapshotTimer = timer
        pushSnapshot(force: true)
        pollInbox()
    }

    struct RemoteSnapshotMessage: Codable {
        let id: String
        let role: String
        let content: String?
        let reasoning: String?
        let toolCalls: [String]?
    }

    struct RemoteSnapshotFrame: Codable {
        let t: String
        let messages: [RemoteSnapshotMessage]
        let busy: Bool
        /// 当前遥控的 Mac 会话 id（手机端会话列表高亮用）
        let session: String?
    }

    private func pushSnapshot(force: Bool) {
        guard connection == .online else { return }
        // 无活动会话也要回空快照：手机端"已连接、空闲"是合法状态，静默会让对端以为信道死了
        let session = remoteSession
        let messages = (session?.messages.suffix(100) ?? []).map { message -> RemoteSnapshotMessage in
            RemoteSnapshotMessage(
                id: message.id.uuidString,
                role: message.role.rawValue,
                content: message.content.map { String($0.prefix(2000)) },
                reasoning: message.reasoning.map { String($0.prefix(600)) },
                toolCalls: message.toolCalls.map { $0.map(\.function.name) })
        }
        let frame = RemoteSnapshotFrame(t: "snapshot", messages: Array(messages),
                                        busy: session?.isProcessing ?? false,
                                        session: remoteConversationID)
        guard let data = try? SyncJSON.makeEncoder().encode(frame) else { return }
        let fingerprint = String(data: data, encoding: .utf8) ?? ""
        if !force && fingerprint == lastSnapshotJSON { return }
        NSLog("REMOTE-DBG push snapshot force=%d busy=%d", force ? 1 : 0, (session?.isProcessing ?? false) ? 1 : 0)
        lastSnapshotJSON = fingerprint
        guard let payload = Self.encrypt(data: data, sessionKeyB64: sessionKeyB64) else { return }
        Self.remoteDebug("snapshot → (\(frame.messages.count) msgs, busy=\(frame.busy))")
        sendTransport(["kind": "route", "payload": payload])
    }

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

    /// 轮询取帧：Mac 端 URLSession WS 下行不可用（实测），控制器指令统一
    /// 从留言表拉取——每秒一拍，与快照推送共用定时器。
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
                 "count": conversation.messages.count]
            }
        let dict: [String: Any] = ["t": "sessions", "list": Array(list)]
        return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"t\":\"sessions\",\"list\":[]}"
    }

    private var pollInFlight = false
    /// 已处理过的取帧 id（服务器重投兜底；处理完立即 ack 删除）
    private var processedInboxIDs: Set<Int64> = []
    private func pollInbox() {
        guard connection == .online, !pollInFlight else { return }
        pollInFlight = true
        Task { @MainActor in
            defer { self.pollInFlight = false }
            guard let token = try? await syncStore.remoteAuthToken() else { return }
            guard let resp = try? await SyncAPIClient.remotePullInbox(
                baseURL: baseURL, accessToken: token, deviceID: syncStore.deviceID) else { return }
            var ackIds: [Int64] = []
            for item in resp.items {
                ackIds.append(item.id)
                guard !self.processedInboxIDs.contains(item.id) else { continue }
                self.processedInboxIDs.insert(item.id)
                if self.processedInboxIDs.count > 500 { self.processedInboxIDs.removeAll() }
                if let inner = Self.decrypt(payloadB64: item.payload, sessionKeyB64: sessionKeyB64) {
                    Self.remoteDebug("pull ← \(String(inner.prefix(100)))")
                    handleInnerFrame(inner)
                }
            }
            if !ackIds.isEmpty {
                self.sendTransport(["kind": "ack", "ids": ackIds])
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
                let deviceName = Host.current().localizedName ?? "Mac"
                let resp = try await SyncAPIClient.remotePairingStart(
                    baseURL: baseURL, accessToken: token,
                    deviceID: syncStore.deviceID, deviceName: deviceName)
                let key = try currentOrCreateSessionKey()
                let qrPayload = RemotePairingQR(
                    v: 1, s: baseURL, c: resp.code, k: key, d: syncStore.deviceID)
                let qrData = try SyncJSON.makeEncoder().encode(qrPayload)
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

    func refreshDevices() {
        guard case .signedIn = syncStore.authState else { return }
        refreshDevicesTask?.cancel()
        refreshDevicesTask = Task { @MainActor in
            do {
                let token = try await syncStore.remoteAuthToken()
                pairedDevices = try await SyncAPIClient.remoteDevices(
                    baseURL: baseURL, accessToken: token).devices
            } catch {
                // 列表刷新失败不打扰（下次打开设置页再试）
            }
        }
    }

    func revoke(deviceID: String, controllerName: String?) {
        Task { @MainActor in
            do {
                let token = try await syncStore.remoteAuthToken()
                try await SyncAPIClient.remotePairingRevoke(
                    baseURL: baseURL, accessToken: token,
                    deviceID: deviceID, controllerName: controllerName)
                refreshDevices()
            } catch {
                connection = .error(error.localizedDescription)
            }
        }
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

/// 传输帧（服务器可见）：inbox / pong。
nonisolated struct RemoteTransportFrame: Codable {
    var kind: String
    var items: [RemoteInboxItem]?
    var payload: String?
}

nonisolated struct RemoteInboxItem: Codable {
    var id: Int64
    var payload: String
}

/// 业务帧（E2E 内层）。t = snapshot/prompt/cancel/sync/error。
nonisolated struct RemoteInnerFrame: Codable {
    var t: String
    var text: String?
    var message: String?
    var body: String?
    var session: String?
}
