import Foundation

struct ReadingListItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
    var savedDate: Date
    var isRead: Bool
    /// 云同步 LWW 戳（optional + 合成 Codable：旧文件缺键解码为 nil，不清数据）
    var updatedAt: Date? = nil
}
