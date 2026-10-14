import Foundation

/// 推广帖（自推广能力）：草稿 → 发布 → 数据回收 的全生命周期记录。
/// 草稿由 Agent 起草（事实以 CHANGELOG/产品页为准），用户在对话里点头后才
/// 发布；发布后记录 URL，之后由 Agent 回访页面把浏览/点赞/评论写回这里。
struct PromotionPost: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case draft
        case published
    }

    /// 平台侧回读的互动数据（可多次更新，保存最近一次）。
    struct Metrics: Codable, Hashable {
        var views: Int?
        var likes: Int?
        var comments: Int?
        var collectedAt: Date?

        var isEmpty: Bool { views == nil && likes == nil && comments == nil }
    }

    let id: UUID
    var goalID: UUID?
    var platform: String
    var title: String
    var body: String
    var status: Status
    var url: String?
    var publishedAt: Date?
    var metrics: Metrics?
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), goalID: UUID? = nil, platform: String, title: String, body: String,
         status: Status = .draft, url: String? = nil, publishedAt: Date? = nil,
         metrics: Metrics? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.goalID = goalID
        self.platform = platform
        self.title = title
        self.body = body
        self.status = status
        self.url = url
        self.publishedAt = publishedAt
        self.metrics = metrics
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
