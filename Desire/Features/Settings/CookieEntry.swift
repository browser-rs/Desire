import Foundation

struct CookieEntry: Identifiable, Equatable {
    let id = UUID()
    let domain: String
    let name: String
    let value: String
    let path: String
    let expiryDate: Date?
    let isSecure: Bool
    let isHttpOnly: Bool
    let sameSitePolicy: String?
}
