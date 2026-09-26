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
}

struct SnapshotFrame: Codable {
    var t: String
    var messages: [ChatMessage]
    var busy: Bool
}

// MARK: - 传输帧（服务器可见：kind = inbox/route/ack/ping/pong/closed）

struct TransportFrame: Codable {
    var kind: String
    var items: [InboxItem]?
    var payload: String?
}

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

struct Envelope<Response: Codable>: Codable {
    var code: Int
    var message: String?
    var data: Response?
}

enum APIError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        if case .server(let message) = self { return message }
        return nil
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
