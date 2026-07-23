import Foundation

/// A CSS media-query result displayed in the responsive-design inspector.
struct MediaQueryItem: Identifiable {
    let id = UUID()
    let query: String
    let isActive: Bool
}
