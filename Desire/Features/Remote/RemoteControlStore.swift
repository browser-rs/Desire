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
@MainActor
final class RemoteControlStore: ObservableObject {

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
        guard webSocketTask == nil else { return }
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
                let task = URLSession.shared.webSocketTask(with: request)
                self.webSocketTask = task
                task.resume()
                self.connection = .online
                self.startSnapshotLoop()
                self.receiveLoop(task)
            } catch {
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

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { @MainActor in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message?
                do {
                    message = try await task.receive()
                } catch {
                    break
                }
                guard let message, !Task.isCancelled else { break }
                switch message {
                case .string(let text):
                    self.handleTransportFrame(text)
                case .data(let data):
                    self.handleTransportFrame(String(data: data, encoding: .utf8) ?? "")
                @unknown default:
                    break
                }
            }
            // 到这里 = 连接断了（若已被更新的连接接管则不管）
            guard self.webSocketTask === task || self.webSocketTask == nil else { return }
            self.webSocketTask = nil
            self.snapshotTimer?.invalidate()
            snapshotTimer = nil
            guard self.isEnabled, case .signedIn = self.syncStore.authState else {
                self.connection = .off
                return
            }
            self.connection = .error(String(localized: "Sync server error"))
            self.scheduleReconnect()
        }
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
        guard let data = text.data(using: .utf8),
              let inner = try? SyncJSON.makeDecoder().decode(RemoteInnerFrame.self, from: data)
        else { return }
        switch inner.t {
        case "prompt":
            let text = inner.text ?? ""
            guard !text.isEmpty else { return }
            if AgentScheduler.shared.deliveryTarget == nil {
                sendInner(["t": "error", "message": String(localized: "No live agent session")])
                return
            }
            AgentScheduler.shared.deliveryTarget?.sendMessage(text, recordHistory: false)
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
            }
        }
        snapshotTimer = timer
        pushSnapshot(force: true)
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
    }

    private func pushSnapshot(force: Bool) {
        guard connection == .online else { return }
        // 无活动会话也要回空快照：手机端"已连接、空闲"是合法状态，静默会让对端以为信道死了
        let session = AgentScheduler.shared.deliveryTarget
        let messages = (session?.messages.suffix(20) ?? []).map { message -> RemoteSnapshotMessage in
            RemoteSnapshotMessage(
                id: message.id.uuidString,
                role: message.role.rawValue,
                content: message.content.map { String($0.prefix(2000)) },
                reasoning: message.reasoning.map { String($0.prefix(600)) },
                toolCalls: message.toolCalls.map { $0.map(\.function.name) })
        }
        let frame = RemoteSnapshotFrame(t: "snapshot", messages: Array(messages), busy: session?.isProcessing ?? false)
        guard let data = try? SyncJSON.makeEncoder().encode(frame) else { return }
        let fingerprint = String(data: data, encoding: .utf8) ?? ""
        if !force && fingerprint == lastSnapshotJSON { return }
        NSLog("REMOTE-DBG push snapshot force=%d busy=%d", force ? 1 : 0, (session?.isProcessing ?? false) ? 1 : 0)
        lastSnapshotJSON = fingerprint
        guard let payload = Self.encrypt(data: data, sessionKeyB64: sessionKeyB64) else { return }
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
}
