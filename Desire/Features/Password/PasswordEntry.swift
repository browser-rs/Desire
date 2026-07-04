import Foundation

struct PasswordEntry: Identifiable {
    let id: UUID
    var domain: String
    var username: String
    var password: String
    var createdAt: Date
}
