import Foundation

struct Bookmark: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
}
