import Foundation

/// 同步服务的错误。401 单列——SyncStore 据此刷新令牌并重试一次。
enum SyncAPIError: LocalizedError {
    case unauthorized
    /// 服务端返回的业务错误（message 可直接展示）
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: String(localized: "Sync session expired")
        case .server(let message): message
        case .network(let message): message
        }
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

    /// 修改密码（登录态）。成功后现有令牌仍有效。
    static func changePassword(
        baseURL: String, accessToken: String, body: SetPasswordReq
    ) async throws {
        _ = try await rawRequest(
            "PUT", baseURL, "/auth/password",
            body: encode(body), token: accessToken
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
        if status == 401 { throw SyncAPIError.unauthorized }
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
struct SyncNull: Codable {}
