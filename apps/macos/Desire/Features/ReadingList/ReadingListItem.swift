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
}
