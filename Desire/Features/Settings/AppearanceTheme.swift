import Foundation
import SwiftUI

enum AppearanceTheme: String, CaseIterable, Codable {
    case system, light, dark
}

enum AccentColor: String, CaseIterable, Codable {
    case blue, purple, pink, red, orange, yellow, green, teal

    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        }
    }
}
