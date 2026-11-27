import Foundation

/// 账号安全接口的解码模型（v0.8.83）：**Foundation-only**，与
/// `RemoteModels.swift` 分开，让 macOS 的纯逻辑 harness 能直接编译并断言
/// 服务端 JSON 形状（iOS target 的 file-system-synchronized group 自动收录）。
struct RecoveryCodeResponse: Codable {
    var recoveryCode: String

    enum CodingKeys: String, CodingKey {
        case recoveryCode = "recovery_code"
    }
}

struct RemoteAuditEvent: Codable, Identifiable, Equatable {
    let id: Int
    let event: String
    let detail: String
    let ip: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, event, detail, ip
        case createdAt = "created_at"
    }
}

struct RemoteAuthDevice: Codable, Identifiable, Equatable {
    let id: Int
    let deviceID: String
    let name: String
    let platform: String
    let revoked: Bool
    let lastSeenAt: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, platform, revoked
        case deviceID = "device_id"
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
    }
}
