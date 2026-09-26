import Foundation

/// 同步服务的错误。401 单列——SyncStore 据此刷新令牌并重试一次。
enum SyncAPIError: LocalizedError {
    /// 令牌失效/过期——SyncStore 据此刷新令牌并重试一次
    case unauthorized(message: String?)
    /// 服务端返回的业务错误（message 可直接展示）
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            message ?? String(localized: "Sync session expired")
        case .server(let message): message
        case .network(let message): message
        }
    }

    /// 供 retry 逻辑判断:错误是否为 401 类
    static func isUnauthorized(_ error: Error) -> Bool {
        if case SyncAPIError.unauthorized = error { return true }
        return false
    }
}

/// 同步服务的 HTTP 客户端（无状态工具）。URLSession + Codable；响应统一走
/// `{code, message, data}` 信封。纯 async——调用方自行挂 Task，不得进启动同步路径。
nonisolated enum SyncAPIClient {

    static func register(baseURL: String, body: SyncAuthBody) async throws -> SyncTokenPair {
        try await send("POST", baseURL, "/auth/register", body: encode(body))
    }

    static func login(baseURL: String, body: SyncAuthBody) async throws -> SyncTokenPair {
        try await send("POST", baseURL, "/auth/login", body: encode(body))
    }

    static func refresh(baseURL: String, refreshToken: String) async throws -> SyncTokenPair {
        try await send(
            "POST", baseURL, "/auth/refresh",
            body: encode(SyncRefreshBody(refreshToken: refreshToken))
        )
    }

    static func logout(baseURL: String, refreshToken: String) async throws {
        _ = try await rawRequest(
            "POST", baseURL, "/auth/logout",
            body: encode(SyncLogoutBody(refreshToken: refreshToken)), token: nil
        )
    }

    /// 注册验证码(公开端点;dev 环境响应附带明文码)。
    static func captcha(baseURL: String) async throws -> SyncCaptcha {
        try await send("GET", baseURL, "/auth/captcha")
    }

    /// 修改密码（登录态）。成功后现有令牌仍有效。
    /// body 内可携带换包字段（E2E）：新盐 + 新包裹 DEK。
    static func changePassword(
        baseURL: String, accessToken: String, body: SetPasswordReq
    ) async throws {
        _ = try await rawRequest(
            "PUT", baseURL, "/auth/password",
            body: encode(body), token: accessToken
        )
    }

    /// 读取密钥托管（盐 + 包裹 DEK + 指纹）。全 nil = 第一台设备。
    static func keyEscrow(baseURL: String, accessToken: String) async throws -> SyncEscrowResp {
        try await send("GET", baseURL, "/sync/key-escrow", token: accessToken)
    }

    // MARK: - 扫码登录（桌面出票显示二维码，手机 App 扫码确认后桌面轮询领 token）

    struct QrCreateBody: Codable {
        var desktop_device_id: String
        var desktop_name: String
    }

    struct QrCreateResp: Codable {
        var ticket: String
        var expiresAt: String
    }

    struct QrStatusResp: Codable {
        /// 0=待扫码 1=已扫码待确认 2=已确认(含 token，一次性领取) 3=过期
        var status: Int
        var accessToken: String?
        var refreshToken: String?
        var username: String?

        enum CodingKeys: String, CodingKey {
            case status
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case username
        }
    }

    struct QrTicketBody: Codable {
        var ticket: String
    }

    static func qrCreate(
        baseURL: String, deviceID: String, deviceName: String
    ) async throws -> QrCreateResp {
        try await send(
            "POST", baseURL, "/auth/qr/create",
            body: encode(QrCreateBody(desktop_device_id: deviceID, desktop_name: deviceName)))
    }

    static func qrStatus(baseURL: String, ticket: String) async throws -> QrStatusResp {
        try await send("GET", baseURL, "/auth/qr/status?ticket=\(ticket)")
    }

    /// 手机端标记"已扫码"（登录态）。
    static func qrScan(baseURL: String, ticket: String, accessToken: String) async throws {
        _ = try await rawRequest(
            "POST", baseURL, "/auth/qr/scan",
            body: encode(QrTicketBody(ticket: ticket)), token: accessToken)
    }

    /// 手机端确认登录（登录态）：服务器为桌面设备签发 token 对。
    static func qrConfirm(baseURL: String, ticket: String, accessToken: String) async throws {
        _ = try await rawRequest(
            "POST", baseURL, "/auth/qr/confirm",
            body: encode(QrTicketBody(ticket: ticket)), token: accessToken)
    }

    // MARK: - 远程控制（配对 REST + 双信箱 push/pull；WS 只做订阅下行，见 RemoteControlStore）

    struct RemotePairingStartBody: Codable {
        var desktop_device_id: String
        var desktop_name: String
    }

    struct RemotePairingStartResp: Codable {
        var code: String
        var expiresAt: String
    }

    struct RemotePairingClaimBody: Codable {
        var code: String
        var controller_name: String
    }

    struct RemotePairingClaimResp: Codable {
        var desktopDeviceId: String
        var desktopName: String
    }

    struct RemotePairedDevice: Codable, Identifiable {
        var desktopDeviceId: String
        var desktopName: String
        var controllerName: String
        var online: Bool
        var createdAt: String
        var id: String { desktopDeviceId + "/" + controllerName }
    }

    struct RemoteDeviceList: Codable {
        var devices: [RemotePairedDevice]
    }

    struct RemoteRevokeBody: Codable {
        var desktop_device_id: String
        var controller_name: String?
    }

    static func remotePairingStart(
        baseURL: String, accessToken: String, deviceID: String, deviceName: String
    ) async throws -> RemotePairingStartResp {
        try await send(
            "POST", baseURL, "/remote/pairing/start",
            body: encode(RemotePairingStartBody(
                desktop_device_id: deviceID, desktop_name: deviceName)),
            token: accessToken)
    }

    static func remotePairingClaim(
        baseURL: String, accessToken: String, code: String, controllerName: String
    ) async throws -> RemotePairingClaimResp {
        try await send(
            "POST", baseURL, "/remote/pairing/claim",
            body: encode(RemotePairingClaimBody(code: code, controller_name: controllerName)),
            token: accessToken)
    }

    static func remoteDevices(baseURL: String, accessToken: String) async throws -> RemoteDeviceList {
        try await send("GET", baseURL, "/remote/devices", token: accessToken)
    }

    struct RemoteInboxPull: Codable {
        var items: [RemoteInboxPullItem]
        /// 收件方为控制器时有意义：桌面 last_seen 戳是否在在线窗口内。
        var desktopOnline: Bool?
    }

    struct RemoteInboxPullItem: Codable {
        var id: Int64
        var payload: String
    }

    /// `role` = 发送方角色（desktop/controller），服务器映射到对端信箱。
    static func remotePullInbox(
        baseURL: String, accessToken: String, deviceID: String, role: String
    ) async throws -> RemoteInboxPull {
        try await send(
            "GET", baseURL, "/remote/pull?role=\(role)&device=\(deviceID)", token: accessToken)
    }

    struct RemotePushBody: Codable {
        var payload: String
        var replace: Bool
    }

    /// 发送业务帧（E2E 密文）：入库（持久、离线可达）+ 服务器 express 发布。
    /// `lane` = "snapshot" 时走独立快照 lane（replace 只清同 lane，不误删回包）。
    static func remotePush(
        baseURL: String, accessToken: String, deviceID: String, role: String,
        lane: String, payload: String, replace: Bool
    ) async throws {
        _ = try await rawRequest(
            "POST", baseURL, "/remote/push?role=\(role)&lane=\(lane)&device=\(deviceID)",
            body: encode(RemotePushBody(payload: payload, replace: replace)),
            token: accessToken)
    }

    static func remotePairingRevoke(
        baseURL: String, accessToken: String, deviceID: String, controllerName: String?
    ) async throws {
        _ = try await rawRequest(
            "POST", baseURL, "/remote/pairing/revoke",
            body: encode(RemoteRevokeBody(
                desktop_device_id: deviceID, controller_name: controllerName)),
            token: accessToken)
    }

    /// 上报托管。指纹与服务器已有不一致 → 409（防拿错密钥覆盖）。
    static func setKeyEscrow(
        baseURL: String, accessToken: String, body: SyncEscrowBody
    ) async throws {
        _ = try await rawRequest(
            "PUT", baseURL, "/sync/key-escrow",
            body: encode(body), token: accessToken
        )
    }

    /// 读取账号的密钥指纹;check = nil 表示该账号还没有任何密文(第一台设备)。
    static func keyCheck(baseURL: String, accessToken: String) async throws -> KeyCheckResp {
        try await send("GET", baseURL, "/sync/key-check", token: accessToken)
    }

    /// 上报本机密钥指纹。与服务器已有指纹不一致时服务端返回 409
    /// (拿错密钥,防止新密钥把旧密文全量覆盖)。
    static func setKeyCheck(
        baseURL: String, fingerprint: String, accessToken: String
    ) async throws {
        _ = try await rawRequest(
            "PUT", baseURL, "/sync/key-check",
            body: encode(KeyCheckBody(check: fingerprint)), token: accessToken
        )
    }

    /// 增量拉取。`since`/`sinceID` 组成复合游标（上次响应末条的
    /// `updatedAt` 原文 + 行 `id`；sinceID 为 nil = 旧版 ts-only 语义）。
    /// 均为 nil = 全量。
    static func pull<P: Codable>(
        baseURL: String, domain: String, since: String?, sinceID: Int64?, accessToken: String
    ) async throws -> SyncPullResponse<P> {
        var path = "/sync/\(domain)"
        var query: [String] = []
        if let since {
            let escaped = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? since
            query.append("since=\(escaped)")
        }
        if let sinceID {
            query.append("since_id=\(sinceID)")
        }
        if !query.isEmpty {
            path += "?" + query.joined(separator: "&")
        }
        return try await send("GET", baseURL, path, token: accessToken)
    }

    /// 批量推送（LWW 仲裁在服务端）。
    static func push<P: Codable>(
        baseURL: String, domain: String, items: [SyncWireItem<P>], accessToken: String
    ) async throws -> [SyncPushResult<P>] {
        let response: SyncPushResponse<P> = try await send(
            "POST", baseURL, "/sync/\(domain)",
            body: encode(SyncPushRequest(items: items)), token: accessToken
        )
        return response.results
    }

    // MARK: - plumbing

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? SyncJSON.makeEncoder().encode(value)
    }

    /// 发请求 → 校验状态码与信封 → 解出 `data`。约束是 Codable：
    /// 信封 `SyncEnvelope<Response>` 要求双向。
    private static func send<Response: Codable>(
        _ method: String, _ baseURL: String, _ path: String,
        body: Data? = nil, token: String? = nil
    ) async throws -> Response {
        let data = try await rawRequest(method, baseURL, path, body: body, token: token)
        guard let envelope = try? SyncJSON.makeDecoder().decode(SyncEnvelope<Response>.self, from: data),
              envelope.code == 0, let payload = envelope.data else {
            throw SyncAPIError.network(String(localized: "Sync server returned invalid data"))
        }
        return payload
    }

    private static func rawRequest(
        _ method: String, _ baseURL: String, _ path: String,
        body: Data?, token: String?
    ) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw SyncAPIError.server(String(localized: "Invalid sync server address"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncAPIError.network(error.localizedDescription)
        }
        let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // 服务器 401 带具体原因(验证码错误/账号禁用等),透出真实消息
            let serverMessage = (try? SyncJSON.makeDecoder().decode(SyncEnvelope<SyncNull>.self, from: data))
                .flatMap { $0.message }
            throw SyncAPIError.unauthorized(message: serverMessage)
        }
        // 200 但信封 code≠0（服务端把错误塞进信封）→ 直接取 message
        let envelope = try? SyncJSON.makeDecoder().decode(SyncEnvelope<SyncNull>.self, from: data)
        if let envelope, envelope.code != 0 {
            throw SyncAPIError.server(envelope.message ?? String(localized: "Sync server error"))
        }
        if !(200...299).contains(status) {
            throw SyncAPIError.server(String(localized: "Sync server error"))
        }
        return data
    }
}

/// 信封 `data: null` 的占位可解码类型。
/// 信封 `data: null` 的占位可解码类型。nonisolated:被本文件的非隔离客户端在任意线程解码。
nonisolated struct SyncNull: Codable {}
