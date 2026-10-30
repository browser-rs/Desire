import Foundation

struct ReadingListItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
    var savedDate: Date
    var isRead: Bool
    /// 云同步 LWW 戳（optional + 合成 Codable：旧文件缺键解码为 nil，不清数据）
    var updatedAt: Date? = nil
    /// 离线缓存（机器本地 .webarchive 路径）。同步到其它设备后文件不存在，
    /// 视为未缓存——字段照常随条目同步，无碍。
    var cachedFile: String? = nil
    var cachedAt: Date? = nil
    /// 批量摘要（v0.7.19 summarizeReadingList）：旁路模型读正文后的 2-3 句摘要。
    /// 可选 + 合成 Codable（旧文件缺键解码为 nil，不清数据）；随云同步走。
    var summary: String? = nil
    var summarizedAt: Date? = nil
    /// 阅读进度（0..1；nil = 未记录）。随条目落盘 + 云同步（LWW 盖戳），
    /// 重开页面自动回到读到的地方。
    var progress: Double? = nil
    var progressAt: Date? = nil
    /// 标签（v0.8.25）：可选 + 合成 Codable（旧文件缺键为 nil，不清数据）；
    /// 同步载荷同样 optional —— 旧客户端 payload 不带该键时保留本地标签。
    var tags: [String]? = nil

    /// 标签列表（归一在 `ReadingListTags.normalize`，写入时保证干净）。
    /// nonisolated：`ReadingListFilter` 是纯逻辑、在非隔离上下文里读它。
    nonisolated var tagList: [String] { tags ?? [] }
}
