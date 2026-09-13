import Foundation

/// A tab container (Firefox multi-account-container style): tabs opened in a
/// container get a dedicated persistent website data store, fully isolating
/// cookies, sessions, and site storage — e.g. logged-in work account vs.
/// personal account on the same site.
struct TabContainer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Index into the shared display palette (mapped to Color in the view layer).
    var colorIndex: Int

    /// Display palette — mapped to actual colors in the view layer
    /// (the model stays SwiftUI-free).
    static let palette: [String] = ["orange", "blue", "green", "purple", "pink", "red", "teal", "indigo"]

    var colorName: String {
        Self.palette[abs(colorIndex) % Self.palette.count]
    }
}
