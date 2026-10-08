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
    /// v0.7.5 智能监视：变化时让 agent 自动分析（opt-in——每次分析是一个
    /// agent 回合，有 token 成本）。
    var aiAnalysis: Bool?
    /// 最近一次 AI 分析文本（回合结束后写回；面板/桥/通知消费）。
    var lastAnalysis: String?

    var wantsAIAnalysis: Bool { aiAnalysis == true }
}
