import Foundation

/// 推广目标（自推广能力）：一句话目标 + 期望平台 + 条数/截止。
/// Agent 的推广工作流（promotionBrief / promotion 技能）按目标输出进度、
/// 决定先写什么、在哪发多少——「按照既定目标推广自己」的数据形态。
struct PromotionGoal: Identifiable, Codable, Hashable {
    let id: UUID
    /// 目标标题（如「v0.7.15 发布宣传」），也是工具/斜杠里匹配目标的自由文本。
    var title: String
    /// 补充说明：受众、角度、语气要求（可空）。
    var objective: String
    /// 期望平台（自由文本：掘金 / V2EX / Hacker News / 微博 …；空 = 不限）。
    var platforms: [String]
    /// 期望条数（nil = 无硬指标）。
    var targetPosts: Int?
    var dueDate: Date?
    var isActive: Bool
    let createdAt: Date

    init(id: UUID = UUID(), title: String, objective: String = "", platforms: [String] = [],
         targetPosts: Int? = nil, dueDate: Date? = nil, isActive: Bool = true,
         createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.objective = objective
        self.platforms = platforms
        self.targetPosts = targetPosts
        self.dueDate = dueDate
        self.isActive = isActive
        self.createdAt = createdAt
    }
}
