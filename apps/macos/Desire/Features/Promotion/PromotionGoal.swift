import Foundation

/// 运营目标（自推广/运营专项）：一句话目标 + 领域 + 期望平台 + 条数/截止。
/// Agent 的运营工作流（promotionBrief / 内置技能）按目标输出进度、
/// 决定先干什么、在哪干多少——「按照既定目标干活」的数据形态。
struct PromotionGoal: Identifiable, Codable, Hashable {
    let id: UUID
    /// 目标标题（如「v0.7.15 发布宣传」），也是工具/斜杠里匹配目标的自由文本。
    var title: String
    /// 补充说明：受众、角度、语气要求（可空）。
    var objective: String
    /// 运营领域：推广 / 自媒体 / 电商。
    var domain: OperationDomain
    /// 期望平台（自由文本：掘金 / V2EX / 小红书 / 淘宝 …；空 = 不限）。
    var platforms: [String]
    /// 期望条数（nil = 无硬指标）。
    var targetPosts: Int?
    var dueDate: Date?
    var isActive: Bool
    let createdAt: Date

    init(id: UUID = UUID(), title: String, objective: String = "",
         domain: OperationDomain = .promotion, platforms: [String] = [],
         targetPosts: Int? = nil, dueDate: Date? = nil, isActive: Bool = true,
         createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.objective = objective
        self.domain = domain
        self.platforms = platforms
        self.targetPosts = targetPosts
        self.dueDate = dueDate
        self.isActive = isActive
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, objective, domain, platforms, targetPosts, dueDate, isActive, createdAt
    }

    // 容错解码（域是后加字段，缺省落到推广——旧数据不整份失败）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        objective = try c.decodeIfPresent(String.self, forKey: .objective) ?? ""
        domain = try c.decodeIfPresent(OperationDomain.self, forKey: .domain) ?? .promotion
        platforms = try c.decodeIfPresent([String].self, forKey: .platforms) ?? []
        targetPosts = try c.decodeIfPresent(Int.self, forKey: .targetPosts)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
