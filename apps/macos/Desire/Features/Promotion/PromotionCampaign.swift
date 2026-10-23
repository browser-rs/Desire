import Foundation

/// 运营战役（v0.8.2）：一次发布/功能/活动的推广单位。目标 → 渠道 → 内容 → 数据
/// 都挂在它下面；`PromotionPost.campaignID` 关联具体帖子。
///
/// 纯数据结构（Foundation-only，进 harness）。状态是人工可改的工作流标签，
/// 不驱动自动发布——发布永远需要用户批准。
nonisolated struct PromotionCampaign: Identifiable, Codable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case planning
        case drafting
        case scheduled
        case publishing
        case review
        case done
        case archived

        var label: String {
            switch self {
            case .planning: String(localized: "Planning")
            case .drafting: String(localized: "Drafting")
            case .scheduled: String(localized: "Scheduled")
            case .publishing: String(localized: "Publishing")
            case .review: String(localized: "Review")
            case .done: String(localized: "Done")
            case .archived: String(localized: "Archived")
            }
        }

        var isOpen: Bool {
            self != .done && self != .archived
        }
    }

    let id: UUID
    var title: String
    var objective: String
    var goalID: UUID?
    /// 版本号（如 "0.8.2"）；功能战役可为 nil。
    var version: String?
    var productURL: String
    /// 渠道平台名（与 PromotionPost.platform / PromotionChannel.platform 对齐）。
    var platforms: [String]
    var status: Status
    var startsAt: Date?
    /// 素材（分享卡图片路径 / 截图路径 / URL）。
    var assets: [String]
    /// 发布日 Runbook（v0.8.3）：相对战役开始日的时间线；nil = 还没生成。
    var runbook: [PromotionRunbookStep]? = nil
    /// 战役简报（生成的 highlights/受众/CTA 摘要，便于复盘）。
    var brief: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, objective: String = "", goalID: UUID? = nil,
         version: String? = nil, productURL: String = "", platforms: [String] = [],
         status: Status = .planning, startsAt: Date? = nil, assets: [String] = [],
         runbook: [PromotionRunbookStep]? = nil,
         brief: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.objective = objective
        self.goalID = goalID
        self.version = version
        self.productURL = productURL
        self.platforms = platforms
        self.status = status
        self.startsAt = startsAt
        self.assets = assets
        self.runbook = runbook
        self.brief = brief
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
