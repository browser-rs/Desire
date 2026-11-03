import Foundation

/// 订阅条件（v0.8.40）：默认终态；可改为失败快报、进度阈值、日志正则命中、
/// 或心跳（定期报“还在跑”）。条件触发不结束 watcher，终态仍会汇总。
nonisolated struct JobWatchCondition: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case terminal, failed, progress, logMatch, heartbeat

        var label: String {
            switch self {
            case .terminal: String(localized: "When finished")
            case .failed: String(localized: "On failure")
            case .progress: String(localized: "At progress")
            case .logMatch: String(localized: "When log matches")
            case .heartbeat: String(localized: "Heartbeat")
            }
        }
    }

    var kind: Kind
    var value: Double?
    var pattern: String?
    var minutes: Int?

    static let terminal = JobWatchCondition(kind: .terminal)
}

/// 后台任务订阅（v0.8.39）。一个 watcher 可以盯一个任务，也可以盯一组
/// （注册时快照的 jobID 列表）；全部进入终态后才回报一次，避免逐条刷屏。
nonisolated struct JobWatch: Identifiable, Codable, Equatable {
    enum Mode: String, Codable {
        /// 只写备注 + 系统通知
        case notify
        /// 备注后，若会话空闲再自动跑一轮“汇报结果”的短回合
        case resume
    }

    var id: UUID
    var jobIDs: [String]
    var conversationID: UUID?
    var mode: Mode
    var reason: String?
    var createdAt: Date
    /// 全部终态并已交付的时间（非 nil = 已完成，保留供诊断）。
    var deliveredAt: Date?
    /// 已交付终态的 jobID → state（去重/诊断）。
    var deliveredStates: [String: String]
    /// resume 是否已用过（每组只允许一次）。
    var resumeUsed: Bool
    /// 订阅条件（nil = 终态；v0.8.40 兼容旧数据）。
    var condition: JobWatchCondition? = nil
    /// 已触发过的非终态条件（防重复；heartbeat 除外）。
    var firedConditionKinds: [String]? = nil
    var lastHeartbeatAt: Date? = nil
    var triggeredAt: Date? = nil

    init(id: UUID = UUID(), jobIDs: [String], conversationID: UUID?,
         mode: Mode, reason: String? = nil, createdAt: Date = Date(),
         deliveredAt: Date? = nil, deliveredStates: [String: String] = [:],
         resumeUsed: Bool = false,
         condition: JobWatchCondition? = nil,
         firedConditionKinds: [String]? = nil,
         lastHeartbeatAt: Date? = nil,
         triggeredAt: Date? = nil) {
        self.id = id
        self.jobIDs = jobIDs
        self.conversationID = conversationID
        self.mode = mode
        self.reason = reason
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.deliveredStates = deliveredStates
        self.resumeUsed = resumeUsed
        self.condition = condition
        self.firedConditionKinds = firedConditionKinds
        self.lastHeartbeatAt = lastHeartbeatAt
        self.triggeredAt = triggeredAt
    }

    var isDone: Bool { deliveredAt != nil }
    var effectiveCondition: JobWatchCondition { condition ?? .terminal }
}
