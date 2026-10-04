import SwiftUI

/// View-layer bridge: `TabContainer.colorIndex` → display color. Keeps the
/// model SwiftUI-free (same pattern as the `AccentColor.color` bridge).
extension TabContainer {
    var color: Color {
        switch colorName {
        case "blue": .blue
        case "green": .green
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "teal": .teal
        case "indigo": .indigo
        default: .orange
        }
    }
}
