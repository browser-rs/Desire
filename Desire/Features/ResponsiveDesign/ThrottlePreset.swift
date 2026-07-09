import Foundation

enum ThrottlePreset: String, CaseIterable, Codable {
    case none, slow3G, fast3G, offline

    var label: String {
        switch self {
        case .none: return "No Throttling"
        case .slow3G: return "Slow 3G"
        case .fast3G: return "Fast 3G"
        case .offline: return "Offline"
        }
    }
}
