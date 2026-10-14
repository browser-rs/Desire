import Foundation

/// 运营经验（持续学习进化的沉淀单元）：Agent 复盘数据后写下的一条可复用
/// 结论（"掘金技术长文比短沸点数据好""周六上午发 V2EX 互动高"）。
/// 注入 promotionBrief 反哺下次起草——数据 → 经验 → 更好的动作 的闭环。
struct PromotionLesson: Identifiable, Codable, Hashable {
    enum Source: String, Codable {
        case agent
        case user
    }

    let id: UUID
    var text: String
    var domain: OperationDomain?
    var platform: String?
    let source: Source
    let createdAt: Date

    init(id: UUID = UUID(), text: String, domain: OperationDomain? = nil,
         platform: String? = nil, source: Source = .agent, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.domain = domain
        self.platform = platform
        self.source = source
        self.createdAt = createdAt
    }
}
