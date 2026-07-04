import Foundation

struct ReadingListItem: Identifiable, Codable {
    let id: UUID
    let title: String
    let url: String
    let savedDate: Date
    var isRead: Bool
}
