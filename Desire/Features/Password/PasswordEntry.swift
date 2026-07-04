import Foundation

struct PasswordEntry: Identifiable, Codable {
    let id: UUID
    var domain: String
    var username: String
    var password: String
    var createdAt: Date
}
