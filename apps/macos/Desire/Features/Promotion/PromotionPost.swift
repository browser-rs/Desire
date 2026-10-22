import Foundation

/// 运营帖（自推广/运营专项）：草稿 → 发布 → 数据回收 的全生命周期记录。
/// 草稿由 Agent 起草（事实以 CHANGELOG/仓库/产品页为准），用户在对话里
/// 点头后才发布；发布后记录 URL，之后每次回访页面都往 `metricHistory`
/// 追加一条快照——增长曲线是「持续学习进化」的一手数据（复盘 → 经验）。
struct PromotionPost: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        /// 选题（选题库里待立项的主意）。
        case idea
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
    /// 所属运营战役（v0.8.2）。Optional + 合成解码：旧帖子/旧文件不受影响。
    var campaignID: UUID?
    /// A/B 变体标记（v0.8.2）：如 "A"/"B"/"标题-疑问句"；nil = 未参与实验。
    var variantLabel: String?
    var platform: String
    var title: String
    var body: String
    var status: Status
    var url: String?
    var publishedAt: Date?
    /// 计划发布日（排期；草稿/选题可带，发布后保留作对照）。
    var plannedFor: Date?
    var metrics: Metrics?
    var metricHistory: [MetricSnapshot]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), goalID: UUID? = nil, campaignID: UUID? = nil,
         variantLabel: String? = nil,
         platform: String, title: String, body: String,
         status: Status = .draft, url: String? = nil, publishedAt: Date? = nil,
         plannedFor: Date? = nil, metrics: Metrics? = nil, metricHistory: [MetricSnapshot] = [],
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.goalID = goalID
        self.campaignID = campaignID
        self.variantLabel = variantLabel
        self.platform = platform
        self.title = title
        self.body = body
        self.status = status
        self.url = url
        self.publishedAt = publishedAt
        self.plannedFor = plannedFor
        self.metrics = metrics
        self.metricHistory = metricHistory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 最新指标：优先聚合字段，缺了回退到快照序列末条（旧数据/直构对象兼容）。
    nonisolated var latestMetrics: Metrics? {
        if let metrics { return metrics }
        guard let last = metricHistory.last else { return nil }
        return Metrics(views: last.views, likes: last.likes, comments: last.comments,
                       collectedAt: last.at)
    }

    /// 首末对比的浏览增长（不足两个快照 / 任一缺值 = nil）。
    nonisolated var viewsGrowth: Int? {
        guard metricHistory.count >= 2,
              let first = metricHistory.first?.views,
              let last = metricHistory.last?.views else { return nil }
        return last - first
    }

    private enum CodingKeys: String, CodingKey {
        case id, goalID, campaignID, variantLabel, platform, title, body, status, url,
             publishedAt, plannedFor, metrics, metricHistory, createdAt, updatedAt
    }

    // 容错解码（metricHistory / campaignID / variantLabel 是后加字段——旧数据不整份失败）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        goalID = try c.decodeIfPresent(UUID.self, forKey: .goalID)
        campaignID = try c.decodeIfPresent(UUID.self, forKey: .campaignID)
        variantLabel = try c.decodeIfPresent(String.self, forKey: .variantLabel)
        platform = try c.decode(String.self, forKey: .platform)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .draft
        url = try c.decodeIfPresent(String.self, forKey: .url)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        plannedFor = try c.decodeIfPresent(Date.self, forKey: .plannedFor)
        metrics = try c.decodeIfPresent(Metrics.self, forKey: .metrics)
        metricHistory = try c.decodeIfPresent([MetricSnapshot].self, forKey: .metricHistory) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}
