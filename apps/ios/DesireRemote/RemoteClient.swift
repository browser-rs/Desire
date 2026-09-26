import Combine
import Foundation
import SwiftUI
import UIKit

/// 远程会话客户端：登录 → 扫码/导入配对 → WS 中继 → 与 Mac 上的 Agent 对话。
/// 信道端到端加密（会话密钥来自配对二维码，服务器不可读）。
@MainActor
final class RemoteClient: ObservableObject {

    enum Phase: Equatable {
        case login, devices, sessions, chat
    }

    struct RemoteSessionInfo: Identifiable, Codable, Equatable {
        var id: String
        var label: String
        var busy: Bool
        var count: Int
    }

    @Published var phase: Phase = .login
    @Published var serverURL: String
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

    static let defaultServer = "https://api.mankong.icu/v9"

    convenience init() {
        self.init(appearance: "")
    }

    init(appearance _: String) {
        appearance = UserDefaults.standard.string(forKey: "remote.appearance") ?? "system"
        serverURL = defaults.string(forKey: "remote.server") ?? Self.defaultServer
        controllerName = UIDevice.current.name
        if let token = defaults.string(forKey: "remote.access"),
           let key = defaults.string(forKey: "remote.sessionKey"),
           let desktop = defaults.string(forKey: "remote.desktopID") {
            accessToken = token
            sessionKeyB64 = key
            desktopDeviceID = desktop
            hasSavedPairing = true
            phase = .sessions
            username = defaults.string(forKey: "remote.username") ?? ""
            // 恢复持久化的对话记录（杀 App 不丢）
            if let data = defaults.data(forKey: "remote.messages"),
               let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                messages = saved
            }
            busy = defaults.bool(forKey: "remote.busy")
            connectWS()
        }
    }

    private var baseURL: String {
        var base = serverURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

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
                defaults.set(pair.accessToken, forKey: "remote.access")
                defaults.set(baseURL, forKey: "remote.server")
                defaults.set(username, forKey: "remote.username")
                phase = .devices
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    private func savedOrCreateDeviceID() -> String {
        if let id = defaults.string(forKey: "remote.deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "remote.deviceID")
        return id
    }

    /// 设置页修改服务器地址（需重新登录才生效到令牌层面）。
    func saveServerURL(_ url: String) {
        var base = url.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return }
        serverURL = base
        defaults.set(base, forKey: "remote.server")
    }

    var savedUsername: String {
        defaults.string(forKey: "remote.username") ?? ""
    }

    func logout() {
        defaults.removeObject(forKey: "remote.access")
        wsTask?.cancel(with: .goingAway, reason: nil)
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
        serverURL = qr.s
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
                defaults.set(qr.k, forKey: "remote.sessionKey")
                defaults.set(resp.desktopDeviceId, forKey: "remote.desktopID")
                defaults.set(baseURL, forKey: "remote.server")
                hasSavedPairing = true
                messages = []
                busy = false
                phase = .sessions
                connectWS()
                requestSessions()
            } catch {
                pairError = error.localizedDescription
            }
        }
    }

    private func currentToken() async throws -> String {
        if let accessToken { return accessToken }
        // access 过期：用 refresh 换新
        guard let refresh = defaults.string(forKey: "remote.refresh") else {
            phase = .login
            throw APIError.server("请重新登录")
        }
        let refreshed: TokenPair = try await API.send(
            "POST", baseURL, "/auth/refresh",
            body: try JSONEncoder().encode(["refresh_token": refresh]))
        accessToken = refreshed.accessToken
        defaults.set(refreshed.accessToken, forKey: "remote.access")
        return refreshed.accessToken
    }

    /// 回到前台：WS 多半已被 iOS 掐断——重连并补快照。
    func appForegrounded() {
        guard phase == .chat, hasSavedPairing, (wsTask == nil) else {
            if phase == .chat { requestSync() }
            return
        }
        connectWS()
    }

    func unpair() {
        defaults.removeObject(forKey: "remote.sessionKey")
        defaults.removeObject(forKey: "remote.desktopID")
        sessionKeyB64 = nil
        desktopDeviceID = nil
        messages = []
        wsTask?.cancel(with: .goingAway, reason: nil)
        hasSavedPairing = false
        phase = .devices
    }

    // MARK: - WebSocket

    private func connectWS() {
        guard let accessToken, let desktopDeviceID else { return }
        var wsBase = baseURL
        if wsBase.hasPrefix("https://") {
            wsBase = "wss://" + wsBase.dropFirst("https://".count)
        } else if wsBase.hasPrefix("http://") {
            wsBase = "ws://" + wsBase.dropFirst("http://".count)
        }
        guard let url = URL(string: "\(wsBase)/remote/ws?role=controller&device=\(desktopDeviceID)") else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        wsTask = task
        task.resume()
        connectionState = "连接中…"
        receiveLoop(task)
        requestSync()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { @MainActor in
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
                handleTransportFrame(text)
            }
            connectionState = "已断开"
        }
    }

    private func handleTransportFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(TransportFrame.self, from: data) else { return }
        switch frame.kind {
        case "route", "inbox":
            let payload = frame.kind == "inbox" ? frame.items?.first?.payload : frame.payload
            guard let payload, let sessionKeyB64,
                  let inner = RemoteCrypto.decrypt(payloadB64: payload, sessionKeyB64: sessionKeyB64) else { return }
            handleInner(inner)
            if frame.kind == "inbox", let id = frame.items?.first?.id {
                sendTransport(["kind": "ack", "ids": [id]])
            }
        case "closed":
            connectionState = "被服务器拒绝（配对可能已吊销）"
        default:
            break
        }
    }

    private func handleInner(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
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
        busy = frame.busy
        connectionState = busy ? "Agent 工作中…" : "已连接"
        if let data = try? JSONEncoder().encode(frame.messages) {
            defaults.set(data, forKey: "remote.messages")
        }
        defaults.set(busy, forKey: "remote.busy")
        if queuedOffline, !busy {
            queuedOffline = false
            connectionState = "已连接"
        }
    }

    private func sendTransport(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        wsTask?.send(.string(text)) { _ in }
    }

    // MARK: - 对外动作

    func sendPrompt(_ text: String) {
        guard let sessionKeyB64 else { return }
        var dict: [String: String] = ["t": "prompt", "text": text]
        if let selectedSessionID { dict["session"] = selectedSessionID }
        guard let payload = RemoteCrypto.innerFrame(dict, sessionKeyB64: sessionKeyB64)
        else { return }
        let offline = connectionState.contains("断开") || connectionState.contains("未连接")
        sendTransport(["kind": "route", "payload": payload, "deliver_if_offline": true])
        queuedOffline = offline
        // 即时回显：不等 Mac 快照，先让指令出现在对话里
        let echo = ChatMessage(id: "echo-\(UUID().uuidString)", role: "user",
                               content: text, reasoning: nil, toolCalls: nil)
        messages.append(echo)
        pendingEcho = echo
        connectionState = offline ? "已排队，Mac 上线后送达" : "Agent 工作中…"
    }

    func sendCancel() {
        guard let sessionKeyB64,
              let payload = RemoteCrypto.innerFrame(["t": "cancel"], sessionKeyB64: sessionKeyB64) else { return }
        sendTransport(["kind": "route", "payload": payload])
    }

    /// 请求 Mac 的会话列表（聊天记录）。
    func requestSessions() {
        guard let sessionKeyB64,
              let payload = RemoteCrypto.innerFrame(["t": "sessions"], sessionKeyB64: sessionKeyB64) else { return }
        sendTransport(["kind": "route", "payload": payload])
    }

    /// 让 Mac 新建一个会话并切过去（列表页"+"按钮）。
    func newSession() {
        guard let sessionKeyB64,
              let payload = RemoteCrypto.innerFrame(["t": "newSession"], sessionKeyB64: sessionKeyB64) else { return }
        sendTransport(["kind": "route", "payload": payload])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            requestSessions()
        }
    }

    /// 打开某个会话（Mac 侧切换遥控目标并回推该会话快照）。
    func selectSession(_ id: String?) {
        selectedSessionID = id
        messages = []
        busy = false
        phase = .chat
        guard let sessionKeyB64 else { return }
        var dict: [String: String] = ["t": "select"]
        if let id { dict["session"] = id }
        if let payload = RemoteCrypto.innerFrame(dict, sessionKeyB64: sessionKeyB64) {
            sendTransport(["kind": "route", "payload": payload])
        }
        requestSync()
    }

    func requestSync() {
        guard let sessionKeyB64,
              let payload = RemoteCrypto.innerFrame(["t": "sync"], sessionKeyB64: sessionKeyB64) else { return }
        sendTransport(["kind": "route", "payload": payload])
    }
}
