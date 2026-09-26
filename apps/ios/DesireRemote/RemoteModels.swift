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

    // MARK: 人工介入 / 进度（与 Mac 端 RemoteSnapshotFrame 对齐；全部可选）

    /// 待审批的工具调用（Agent 挂起等 Allow Once / Always Allow / Deny）
    var approval: RemoteApproval?
    /// Agent 的反问（askUser 挂起等回答）
    var question: RemoteQuestion?
    /// updatePlan 维护的任务清单
    var plan: [RemotePlanStep]?
    /// 子代理实时进度
    var subagents: [RemoteSubagent]?
    /// 回合进行中输入、排队待发的消息
    var queued: [RemoteQueued]?
    /// Agent 将要操作的目标页（"Title — host"）
    var context: String?
    /// FULL ACCESS：所有工具免审批
    var fullAccess: Bool?
    /// 上一轮已结束且末条是 assistant → 可重新生成
    var canRegenerate: Bool?
    /// 快捷动作（Mac 为唯一文案来源）
    var quickActions: [RemoteQuickAction]?

    // MARK: 会话状态补充

    /// 回合被暂停（pause 后、resume 前）
    var paused: Bool?
    /// 本对话累计 token（0 时 Mac 不传）
    var tokens: Int?
    /// 本对话累计成本（未填单价时 Mac 不传——不显示 0）
    var cost: String?
    /// Mac 的显示名（持续下发，冷启动也有真名可显示）
    var desktop: String?
}

// MARK: - 快照子载荷

struct RemoteApproval: Codable, Identifiable, Equatable {
    var id: String
    var tool: String
    /// readonly | sideEffect | dangerous
    var risk: String
    var summary: String
    /// dangerous 档不提供"始终允许"
    var dangerous: Bool

    var riskDisplay: String {
        switch risk {
        case "readonly": "只读安全"
        case "dangerous": "执行代码"
        default: "改变状态"
        }
    }
}

struct RemoteQuestion: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    /// 兜底超时（秒）
    var timeout: Int
}

struct RemotePlanStep: Codable, Equatable {
    var content: String
    /// pending | in_progress | done
    var status: String
}

struct RemoteSubagent: Codable, Equatable {
    var label: String
    var step: Int
    var maxSteps: Int
    var tool: String?
}

struct RemoteQueued: Codable, Identifiable, Equatable {
    var id: String
    var text: String
}

struct RemoteQuickAction: Codable, Identifiable, Equatable {
    var key: String
    var title: String
    var icon: String

    var id: String { key }
}

/// 审批决定（approve 指令的 decision 字段）。
enum RemoteApprovalDecision: String {
    case allowOnce
    case alwaysAllow
    case deny
}

// MARK: - 按需拉取的只读信息帧（与 Mac 端 *Frame 组装函数一一对齐）

/// 能力与工具（`t: "capabilities"`）：Agent 能调用的全部工具 + 技能库。
struct RemoteCapabilities: Codable, Equatable {
    var tools: [RemoteToolInfo]
    var skills: [RemoteSkillInfo]
}

struct RemoteToolInfo: Codable, Identifiable, Equatable {
    var name: String
    var description: String
    /// readonly | sideEffect | dangerous
    var risk: String

    var id: String { name }

    /// 与桌面 `ToolRisk.displayName` 同义的中文档位。
    var riskDisplay: String {
        switch risk {
        case "readonly": "只读安全"
        case "dangerous": "执行代码"
        default: "改变状态"
        }
    }
}

struct RemoteSkillInfo: Codable, Identifiable, Equatable {
    var name: String
    var description: String

    var id: String { name }
}

/// 跨会话用量统计（`t: "stats"`）。
struct RemoteStats: Codable, Equatable {
    var totalTokens: Int
    var promptTokens: Int
    var completionTokens: Int
    var turns: Int
    var conversations: Int
    var unpricedTokens: Int
    var peakDayTokens: Int?
    var longestConversationSeconds: Double
    var currentStreak: Int
    var longestStreak: Int
    /// nil = 有未定价的调用（总额不完整，Mac 端刻意不给数）
    var cost: Double?
    var models: [RemoteModelUsage]
}

struct RemoteModelUsage: Codable, Identifiable, Equatable {
    var model: String
    var tokens: Int
    var promptTokens: Int?
    var completionTokens: Int?
    var cost: Double?

    var id: String { model }
}

/// 当前会话轨迹（`t: "trace"`）。
struct RemoteTrace: Codable, Equatable {
    var turns: [RemoteTraceTurn]
    var stats: RemoteTraceStats
}

struct RemoteTraceTurn: Codable, Identifiable, Equatable {
    var turn: Int
    var goal: String
    var answer: String?
    var toolCalls: Int
    var startedAt: String?
    var tokens: RemoteTokenSplit?
    var cost: Double?
    var model: String?
    var steps: [RemoteTraceStep]

    var id: Int { turn }
}

struct RemoteTokenSplit: Codable, Equatable {
    var prompt: Int
    var completion: Int
    var total: Int
}

struct RemoteTraceStep: Codable, Equatable {
    var action: String
    var ms: Double?
    var denied: Bool?
    var failed: Bool?
}

/// 轨迹聚合统计（与桌面「用量」页同口径；全可选，因为空会话时 Mac 回 `{}`）。
struct RemoteTraceStats: Codable, Equatable {
    var turns: Int?
    var toolCalls: Int?
    var denied: Int?
    var threwError: Int?
    var avgToolMs: Double?
    var unverifiedTurns: Int?
    var votesUp: Int?
    var votesDown: Int?
    var promptTokens: Int?
    var completionTokens: Int?
    var cost: Double?
    var costIncomplete: Bool?
    var slowestTools: [RemoteToolStat]?
    var flakiestTools: [RemoteToolStat]?
}

struct RemoteToolStat: Codable, Equatable {
    var tool: String
    var calls: Int
    var failed: Int?
    var avgMs: Double?
}

/// 模型服务档案（`t: "models"`）。
struct RemoteModels: Codable, Equatable {
    var profiles: [RemoteProfile]
    /// 当前档案 id
    var active: String
    /// 当前档案的候选模型
    var models: [String]
}

struct RemoteProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var model: String
}

// MARK: - 扫码登录（手机扫 Mac 二维码后确认）

struct QrTicketBody: Codable {
    var ticket: String
}

struct QrScanResp: Codable {
    var desktopName: String?
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
