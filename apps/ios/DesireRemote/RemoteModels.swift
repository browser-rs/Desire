import Foundation

/// 与 Mac 端 RemoteControlStore 对齐的线路模型（E2E 内层协议）。

// MARK: - 二维码载荷（Mac 设置页生成）

struct PairingQRPayload: Codable {
    var v: Int
    /// 中继服务器 base（含账号体系）
    var s: String
    /// 一次性配对码
    var c: String
    /// 会话密钥（AES-256，base64）
    var k: String
    /// 目标 Mac 的设备 id
    var d: String
}

// MARK: - 快照消息（Mac 1 秒一拍、变化才发）

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let role: String
    let content: String?
    let reasoning: String?
    let toolCalls: [String]?
    /// 与 toolCalls 一一对应的参数摘要（Mac 截 160 字符）
    var toolArgs: [String]? = nil
}

struct SnapshotFrame: Codable {
    var t: String
    var messages: [ChatMessage]
    var busy: Bool
    /// Mac 当前遥控的会话 id（新建会话后手机据此锁定选中）
    var session: String?
    /// Agent 状态行
    var model: String?
    var contextPercent: Int?
    var queueCount: Int?
    var elapsed: Int?
}

// MARK: - Agent 记忆（t = "memory"）

struct AgentMemory: Codable {
    var t: String
    var profileName: String
    var profileLanguage: String
    var profileStyle: String
    var profileCustom: String
    var facts: [MemoryFactInfo]
    var summaries: [MemorySummaryInfo]

    var profileNonEmpty: Bool {
        !(profileName.isEmpty && profileLanguage.isEmpty && profileStyle.isEmpty && profileCustom.isEmpty)
    }
}

struct MemoryFactInfo: Codable, Identifiable, Equatable {
    var id: String
    var content: String
    var category: String
    var pinned: Bool
    var scope: String
}

struct MemorySummaryInfo: Codable, Identifiable, Equatable {
    var id: String
    var summary: String
}

// MARK: - 信箱帧（WS express 与 pull 兜底共用同一形态）

struct InboxItem: Codable {
    var id: Int64
    var payload: String
}

// MARK: - REST DTO

struct LoginBody: Codable {
    var username: String
    var password: String
    var device: DeviceBody
    struct DeviceBody: Codable {
        var device_id: String
        var device_name: String
        var platform: String
    }
}

struct TokenPair: Codable {
    var accessToken: String
    var refreshToken: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct ClaimBody: Codable {
    var code: String
    var controller_name: String
}

struct ClaimResp: Codable {
    var desktopDeviceId: String
    var desktopName: String
}

/// GET /remote/pull 响应（双信箱；desktopOnline 供控制器判定 Mac 是否在线）
struct PullResp: Codable {
    var items: [InboxItem]
    var desktopOnline: Bool?
}

/// POST /remote/push 请求体（replace = 作废对端信箱里的 pending 旧帧，快照用）
struct PushBody: Codable {
    var payload: String
    var replace: Bool
}

struct PushOK: Codable {
    var ok: Bool
}

struct RevokeBody: Codable {
    var desktop_device_id: String
    var controller_name: String
}

struct RevokeResp: Codable {
    var revoked: Int
}

struct Envelope<Response: Codable>: Codable {
    var code: Int
    var message: String?
    var data: Response?
}

enum APIError: LocalizedError {
    case server(String)
    /// HTTP 401 —— 令牌过期，调用方（authedSend）刷新后重试一次
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .unauthorized(let message): message
        }
    }
}

/// 无状态 HTTP 客户端（信封 {code,message,data}）。
enum API {
    static func send<Response: Codable>(
        _ method: String, _ baseURL: String, _ path: String,
        body: Data? = nil, token: String? = nil
    ) async throws -> Response {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.server("无效的服务器地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            let message = (try? JSONDecoder().decode(Envelope<Empty>.self, from: data))?
                .message ?? "登录已过期"
            throw APIError.unauthorized(message)
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<Response>.self, from: data),
              envelope.code == 0, let payload = envelope.data else {
            let message = (try? JSONDecoder().decode(Envelope<Empty>.self, from: data))?
                .message ?? "服务器错误 (HTTP \(status))"
            throw APIError.server(message)
        }
        return payload
    }

    struct Empty: Codable {}
}
