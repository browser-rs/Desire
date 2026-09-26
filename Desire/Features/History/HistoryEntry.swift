import Foundation

struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    var url: String
    var title: String
    var timestamp: Date
    /// 本地最后修改时间（云同步 LWW 盖戳；标题校正等编辑会推进）。
    /// 旧本地文件缺键 → nil，加载时以 timestamp 兜底归一（不清数据）。
    var updatedAt: Date? = nil
}
