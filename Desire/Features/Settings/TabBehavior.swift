import Foundation

enum NewTabPosition: String, CaseIterable, Codable {
    case end
    case afterCurrent
}

enum StartupBehavior: String, CaseIterable, Codable {
    case restoreSession
    case newTabPage
}

enum AutoPlayPolicy: String, CaseIterable, Codable {
    case allowAll
    case requireUserAction
    case never
}
