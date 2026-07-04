import Foundation

struct UserScript: Identifiable, Codable {
    let id: UUID
    var name: String
    var urlPattern: String
    var code: String
    var isEnabled: Bool
}
