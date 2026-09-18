import Foundation

/// A deterministic page monitor: periodically loads a URL in an offscreen
/// webview, extracts text (whole body or a CSS selector), and reports
/// changes. Unlike scheduled agent tasks this never touches a model —
/// cheap enough to run every few minutes forever.
struct PageWatch: Codable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    /// Optional CSS selector; nil/empty watches the whole body text.
    var selector: String?
    /// Minimum 5 minutes — tighter intervals are pointless for page watches.
    var intervalMinutes: Int
    var isEnabled: Bool
    var createdAt: Date
    var lastCheckedAt: Date?
    var lastChangedAt: Date?
    /// Normalized text from the previous check (diff baseline), capped.
    var previousText: String?
    var changeCount: Int
    var lastError: String?
}
