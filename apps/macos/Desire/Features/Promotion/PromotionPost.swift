import Foundation

/// 运营帖（自推广/运营专项）：草稿 → 发布 → 数据回收 的全生命周期记录。
/// 草稿由 Agent 起草（事实以 CHANGELOG/仓库/产品页为准），用户在对话里
/// 点头后才发布；发布后记录 URL，之后每次回访页面都往 `metricHistory`
/// 追加一条快照——增长曲线是「持续学习进化」的一手数据（复盘 → 经验）。
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

    /// 一次采集的快照（全部追加进 metricHistory，保增长可回溯）。
    struct MetricSnapshot: Codable, Hashable {
        let at: Date
        var views: Int?
        var likes: Int?
        var comments: Int?
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
    var metricHistory: [MetricSnapshot]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), goalID: UUID? = nil, platform: String, title: String, body: String,
         status: Status = .draft, url: String? = nil, publishedAt: Date? = nil,
         metrics: Metrics? = nil, metricHistory: [MetricSnapshot] = [],
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.goalID = goalID
        self.platform = platform
        self.title = title
        self.body = body
        self.status = status
        self.url = url
        self.publishedAt = publishedAt
        self.metrics = metrics
        self.metricHistory = metricHistory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 首末对比的浏览增长（不足两个快照 / 任一缺值 = nil）。
    nonisolated var viewsGrowth: Int? {
        guard metricHistory.count >= 2,
              let first = metricHistory.first?.views,
              let last = metricHistory.last?.views else { return nil }
        return last - first
    }

    private enum CodingKeys: String, CodingKey {
        case id, goalID, platform, title, body, status, url, publishedAt, metrics,
             metricHistory, createdAt, updatedAt
    }

    // 容错解码（metricHistory 是后加字段——旧数据不整份失败）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        goalID = try c.decodeIfPresent(UUID.self, forKey: .goalID)
        platform = try c.decode(String.self, forKey: .platform)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .draft
        url = try c.decodeIfPresent(String.self, forKey: .url)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        metrics = try c.decodeIfPresent(Metrics.self, forKey: .metrics)
        metricHistory = try c.decodeIfPresent([MetricSnapshot].self, forKey: .metricHistory) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}
