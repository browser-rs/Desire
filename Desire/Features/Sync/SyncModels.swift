import Foundation

/// 云同步（crates/api 后端）客户端 Model 层：线路 DTO、时间编解码、
/// JSON 编解码器工厂。只 import Foundation——纯逻辑单测（tests/run.sh）覆盖。

/// 开放同步的域（rawValue = 服务端路径段，须与 sync_model::DOMAINS 白名单一致）。
enum SyncDomain: String, CaseIterable {
    case bookmarks
    case quickDials = "quickdials"
    case readingList = "reading_list"
    case keyboardShortcuts = "keyboard_shortcuts"
    /// 设置 KV（client_id = 设置键名）
    case settings
    /// Agent 记忆（事实/摘要/画像；对话本身按用户决定永久留本地）
    case agentMemory = "agent_memory"
    /// Agent 自定义系统提示词
    case agentPrefs = "agent_prefs"
}

/// 书签域的 payload(密文内部结构,服务器不解读)。
/// 一个节点一条:树结构由 parentID + sort 表达,children 不进 payload;
/// `id` = 真实节点 UUID(线上 client_id 是它的 HMAC,解密后以这里为准)。
struct BookmarkSyncPayload: Codable, Equatable {
    var id: UUID
    var parentID: UUID?
    var title: String
    var url: String?
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case title
        case url
        case sort
    }
}

/// 服务端（rust/chrono）的时间是 **naive** ISO 字符串且小数位可变
/// （"2026-09-24T12:00:00" / ".5" / ".123456"，chrono 会裁掉尾零）。
/// 服务端固定存 UTC（连接 SET time_zone '+00:00'），这里按 UTC 解析与生成。
nonisolated enum SyncDate {
    // DateFormatter 自 macOS 10.9 起线程安全且标了 Sendable；只读共享无碍。
    private static let baseFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        let base: Substring
        let fraction: Substring?
        if let dot = raw.firstIndex(of: ".") {
            base = raw[..<dot]
            fraction = raw[raw.index(after: dot)...]
        } else {
            base = raw[...]
            fraction = nil
        }
        guard let parsed = baseFormatter.date(from: String(base)) else { return nil }
        guard let frac = fraction, !frac.isEmpty, let ratio = Double("0." + frac) else {
            return parsed
        }
        return parsed.addingTimeInterval(ratio)
    }

    /// 固定 6 位小数（微秒，与 MySQL datetime(6) 对齐）。
    static func encode(_ date: Date) -> String {
        let totalMicros = Int((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
        let base = baseFormatter.string(from: Date(timeIntervalSince1970: Double(totalMicros / 1_000_000)))
        return base + String(format: ".%06d", totalMicros % 1_000_000)
    }
}

/// 同步域统一的 JSON 编解码器：snake_case 线路键由各 DTO 的 CodingKeys
/// 显式映射；Date 走 SyncDate。每次调用新建实例（JSONDecoder 不保证可并发复用）。
nonisolated enum SyncJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = SyncDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "无法解析同步时间: \(raw)"
                )
            }
            return date
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SyncDate.encode(date))
        }
        return encoder
    }
}

/// `/sync/{domain}` 的载荷信封（E2E）：v = 格式版本，ct = AES-256-GCM
/// combined（nonce+密文+tag）的 base64。明文结构由客户端定义（含真实 id），
/// 服务器只透传。见 SyncCrypto。
struct SyncEncryptedPayload: Codable, Equatable {
    var v: Int
    var ct: String
}

/// `/sync/{domain}` 的线路条目。payload 泛型（每域一个类型）；
/// `id` 是服务端行 id（pull 响应携带，复合游标第二分量）；
/// `updatedAt` 是服务端写入时间**原文**——客户端把它当拉取游标原样回传，
/// 不做解析（避免时间精度往返误差）。
struct SyncWireItem<Payload: Codable>: Codable {
    var clientId: String
    var clientUpdatedAt: Date
    /// push 请求必须显式带（服务端 serde default 只在键缺席时兜底）
    var deleted: Bool?
    var payload: Payload?
    var id: Int64?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientUpdatedAt = "client_updated_at"
        case deleted
        case payload
        case id
        case updatedAt = "updated_at"
    }
}

struct SyncPullResponse<Payload: Codable>: Codable {
    var items: [SyncWireItem<Payload>]
    var serverTime: String?

    enum CodingKeys: String, CodingKey {
        case items
        case serverTime = "server_time"
    }
}

struct SyncPushRequest<Payload: Codable>: Codable {
    var items: [SyncWireItem<Payload>]
}

struct SyncPushResult<Payload: Codable>: Codable {
    var clientId: String
    /// applied = 采纳；conflict = 服务端版本更新，item 给回胜者（客户端应采纳）
    var status: String
    var item: SyncWireItem<Payload>?

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case status
        case item
    }
}

struct SyncPushResponse<Payload: Codable>: Codable {
    var results: [SyncPushResult<Payload>]
}

/// 设置 KV 域的载荷(密文内部):key = 设置键名(敏感,线上只见其 HMAC),
/// value = 值本体(带类型标签:string/bool/number)。
struct SettingsSyncEntryPayload: Codable, Equatable {
    var key: String
    var value: SettingsSyncValue
}

/// Agent 偏好域的载荷（密文内部）：自定义系统提示词。
struct AgentPrefsSyncPayload: Codable, Equatable {
    var systemPrompt: String
}

/// 值本体(带类型标签的 JSON)。
enum SettingsSyncValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)

    private enum CodingKeys: String, CodingKey { case s, b, n }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? container.decode(String.self, forKey: .s) { self = .string(v); return }
        if let v = try? container.decode(Bool.self, forKey: .b) { self = .bool(v); return }
        if let v = try? container.decode(Double.self, forKey: .n) { self = .number(v); return }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "未知设置值类型"
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v): try container.encode(v, forKey: .s)
        case .bool(let v): try container.encode(v, forKey: .b)
        case .number(let v): try container.encode(v, forKey: .n)
        }
    }
}

/// 响应信封：成功 code=0；错误 code=HTTP 语义值、message 可直接展示。
/// nonisolated：被非隔离的 SyncAPIClient 直接访问成员。
nonisolated struct SyncEnvelope<Data: Codable>: Codable {
    var code: Int
    var message: String?
    var data: Data?
}

// MARK: - Auth DTOs

struct SyncTokenPair: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct SyncMe: Codable {
    var id: Int
    var username: String
    var nickname: String
    var email: String
}

struct SyncAuthBody: Codable {
    var username: String
    var password: String
    var nickname: String?
    var device: SyncDeviceBody?
    /// 仅注册携带；登录省略
    var captchaId: String?
    var captchaCode: String?

    enum CodingKeys: String, CodingKey {
        case username, password, nickname, device
        case captchaId = "captcha_id"
        case captchaCode = "captcha_code"
    }
}

struct SyncCaptcha: Codable {
    var captchaId: String
    /// PNG 的标准 base64
    var image: String
    /// dev 环境回显的明文码；prod 无
    var code: String?

    enum CodingKeys: String, CodingKey {
        case captchaId = "captcha_id"
        case image
        case code
    }
}

struct SyncDeviceBody: Codable {
    var deviceID: String
    var name: String?
    var platform: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case platform
    }
}

struct SyncRefreshBody: Codable {
    var refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct SyncLogoutBody: Codable {
    var refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct SetPasswordReq: Codable {
    var oldPassword: String
    var newPassword: String
    /// 改密时同步换包(新盐 + 新 KEK 包裹的 DEK);缺省 = 无托管
    var newKdfSalt: String?
    var newWrappedDek: String?

    enum CodingKeys: String, CodingKey {
        case oldPassword = "old_password"
        case newPassword = "new_password"
        case newKdfSalt = "new_kdf_salt"
        case newWrappedDek = "new_wrapped_dek"
    }
}

/// 托管的包裹 DEK(JSON 信封,客户端加解密,服务端存原文)。
/// nonisolated:被非隔离的 SyncCrypto 在任意线程编解码。
nonisolated struct SyncWrappedDek: Codable, Equatable {
    var v: Int
    /// 目前固定 pbkdf2-sha256
    var kdf: String
    var iter: Int
    /// AES-GCM combined 的 base64
    var ct: String
}

struct SyncEscrowResp: Codable {
    /// nil = 该账号尚未托管密钥(第一台设备)
    var kdfSalt: String?
    var wrappedDek: String?
    var keyCheck: String?

    enum CodingKeys: String, CodingKey {
        case kdfSalt = "kdf_salt"
        case wrappedDek = "wrapped_dek"
        case keyCheck = "key_check"
    }
}

struct SyncEscrowBody: Codable {
    var kdfSalt: String
    var wrappedDek: String
    var keyCheck: String

    enum CodingKeys: String, CodingKey {
        case kdfSalt = "kdf_salt"
        case wrappedDek = "wrapped_dek"
        case keyCheck = "key_check"
    }
}

struct KeyCheckResp: Codable {
    /// nil = 该账号还没有设置密钥（第一台设备）
    var check: String?
}

struct KeyCheckBody: Codable {
    var check: String
}
