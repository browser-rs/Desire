import Foundation

/// 统一作业账本的一条记录（v0.8.2）。只记录**本应用发起的可交付工作**：
/// 发布准备、提及扫描、战役生成、后续的后台 Agent/数据采集/文件整理等。
///
/// 纯数据结构（Foundation-only，进 harness）。已有下载/批量/定时等子系统
/// 继续做自己的状态真相；Job 账本只保存跨子系统的交付视图，不复制状态。
nonisolated struct JobRecord: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case publish
        case mentionScan
        case campaign
        case scheduled
        case download
        case agent
        case other

        var label: String {
            switch self {
            case .publish: String(localized: "Publish")
            case .mentionScan: String(localized: "Mention scan")
            case .campaign: String(localized: "Campaign")
            case .scheduled: String(localized: "Scheduled task")
            case .download: String(localized: "Download")
            case .agent: String(localized: "Agent task")
            case .other: String(localized: "Job")
            }
        }

        var icon: String {
            switch self {
            case .publish: "paperplane"
            case .mentionScan: "dot.radiowaves.left.and.right"
            case .campaign: "flag.checkered"
            case .scheduled: "clock.arrow.circlepath"
            case .download: "arrow.down.circle"
            case .agent: "sparkles"
            case .other: "square.stack.3d.up"
            }
        }
    }

    enum State: String, Codable, CaseIterable {
        case queued
        case running
        case needsReview
        case needsApproval
        case done
        case failed
        case cancelled

        var isActive: Bool {
            switch self {
            case .queued, .running, .needsReview, .needsApproval: true
            case .done, .failed, .cancelled: false
            }
        }

        var label: String {
            switch self {
            case .queued: String(localized: "Queued")
            case .running: String(localized: "Running")
            case .needsReview: String(localized: "Needs review")
            case .needsApproval: String(localized: "Needs approval")
            case .done: String(localized: "Done")
            case .failed: String(localized: "Failed")
            case .cancelled: String(localized: "Cancelled")
            }
        }

        var icon: String {
            switch self {
            case .queued: "clock"
            case .running: "arrow.triangle.2.circlepath"
            case .needsReview: "eye"
            case .needsApproval: "hand.raised"
            case .done: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .cancelled: "xmark.circle"
            }
        }
    }

    let id: UUID
    var title: String
    var kind: Kind
    var state: State
    var detail: String
    var progress: Double?
    /// 产物：http(s) URL 或本地文件路径。
    var artifactURL: String?
    /// 结果证据 / 说明（做了什么、填了哪些字段、扫描了多少来源）。
    var receipt: String?
    var error: String?
    /// 来源（operations / campaign:<uuid> / scheduler …）。
    var source: String?
    /// 外部对象 id（post uuid / conversation id），用于回写状态。
    var externalID: String?
    let createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?

    init(id: UUID = UUID(), title: String, kind: Kind, state: State = .queued,
         detail: String = "", progress: Double? = nil, artifactURL: String? = nil,
         receipt: String? = nil, error: String? = nil, source: String? = nil,
         externalID: String? = nil, createdAt: Date = Date(),
         updatedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.state = state
        self.detail = detail
        self.progress = progress
        self.artifactURL = artifactURL
        self.receipt = receipt
        self.error = error
        self.source = source
        self.externalID = externalID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }

    var isTerminal: Bool { !state.isActive }
    var canDismiss: Bool { state.isActive }
}
