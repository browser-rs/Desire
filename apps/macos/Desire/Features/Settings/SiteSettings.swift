import Foundation

/// Per-site settings persisted by `SiteSettingsStore` (zoom level, dark-mode
/// override, blocked CSS selectors for a given host).
struct SiteSettings: Codable {
    var zoom: Double
    var darkMode: Bool = false
    var blockedSelectors: [String] = []
}
