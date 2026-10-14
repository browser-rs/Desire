import Foundation

/// 运营账号（自媒体/电商专项）：一个平台上的一个可运营身份
/// （掘金账号、公众号、店铺、淘宝店…）。快照序列追踪粉丝/曝光等指标的
/// 长期变化——「持续学习进化」的一手数据（趋势由 Agent 复盘成经验）。
struct PromotionAccount: Identifiable, Codable, Hashable {
    /// 单个时点的账号数据（平台口径不同，能填多少填多少）。
    struct Snapshot: Codable, Hashable {
        let at: Date
        var followers: Int?
        var views: Int?
        var likes: Int?
    }

    let id: UUID
    var domain: OperationDomain
    var platform: String
    /// 账号名 / handle（同平台内 upsert 的键）。
    var handle: String
    var url: String?
    var note: String
    var isActive: Bool
    let createdAt: Date
    var snapshots: [Snapshot]

    init(id: UUID = UUID(), domain: OperationDomain = .media, platform: String, handle: String,
         url: String? = nil, note: String = "", isActive: Bool = true,
         createdAt: Date = Date(), snapshots: [Snapshot] = []) {
        self.id = id
        self.domain = domain
        self.platform = platform
        self.handle = handle
        self.url = url
        self.note = note
        self.isActive = isActive
        self.createdAt = createdAt
        self.snapshots = snapshots
    }

    nonisolated var latest: Snapshot? { snapshots.last }

    /// 首末对比的粉丝增长（不足两个快照 / 任一缺值 = nil）。
    nonisolated var followersGrowth: Int? {
        guard snapshots.count >= 2,
              let first = snapshots.first?.followers,
              let last = snapshots.last?.followers else { return nil }
        return last - first
    }

    private enum CodingKeys: String, CodingKey {
        case id, domain, platform, handle, url, note, isActive, createdAt, snapshots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        domain = try c.decodeIfPresent(OperationDomain.self, forKey: .domain) ?? .media
        platform = try c.decode(String.self, forKey: .platform)
        handle = try c.decode(String.self, forKey: .handle)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        snapshots = try c.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
    }
}
