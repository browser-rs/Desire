import Foundation

/// 运营渠道档案（v0.8.2）：一个平台上的发布口味与硬限制。生成草稿时按它裁剪
/// 标题/正文、加标签、排发布节奏；后续发布流水线也用它的 composerURL。
nonisolated struct PromotionChannel: Identifiable, Codable, Equatable {
    enum Voice: String, Codable {
        case x
        case xiaohongshu
        case technical
        case longform
        case microblog
        case hackerNews
    }

    /// 稳定 slug（UTM source / 预设查找键）。
    var slug: String
    var platform: String
    var composerURL: String?
    var voice: Voice
    var maxTitleLength: Int
    var maxBodyLength: Int
    var hashtags: String
    var isEnabled: Bool

    var id: String { slug }

    init(slug: String, platform: String, composerURL: String? = nil,
         voice: Voice, maxTitleLength: Int, maxBodyLength: Int,
         hashtags: String = "", isEnabled: Bool = true) {
        self.slug = slug
        self.platform = platform
        self.composerURL = composerURL
        self.voice = voice
        self.maxTitleLength = maxTitleLength
        self.maxBodyLength = maxBodyLength
        self.hashtags = hashtags
        self.isEnabled = isEnabled
    }

    /// 预置常见渠道。composerURL 只是起点，平台改版后仍可按工作流覆盖。
    static let presets: [PromotionChannel] = [
        PromotionChannel(
            slug: "x", platform: "X", composerURL: "https://x.com/compose/post",
            voice: .x, maxTitleLength: 80, maxBodyLength: 1200,
            hashtags: "#macOS #browser"),
        PromotionChannel(
            slug: "xiaohongshu", platform: "小红书",
            composerURL: "https://creator.xiaohongshu.com/publish/publish",
            voice: .xiaohongshu, maxTitleLength: 20, maxBodyLength: 900,
            hashtags: "#macOS #浏览器 #效率工具 #AI工具"),
        PromotionChannel(
            slug: "v2ex", platform: "V2EX", composerURL: "https://www.v2ex.com/new",
            voice: .technical, maxTitleLength: 60, maxBodyLength: 2000),
        PromotionChannel(
            slug: "juejin", platform: "掘金",
            composerURL: "https://juejin.cn/editor/drafts/new",
            voice: .longform, maxTitleLength: 60, maxBodyLength: 3000),
        PromotionChannel(
            slug: "jike", platform: "即刻", composerURL: "https://web.okjike.com/",
            voice: .microblog, maxTitleLength: 40, maxBodyLength: 500),
        PromotionChannel(
            slug: "hackernews", platform: "Hacker News",
            composerURL: "https://news.ycombinator.com/submit",
            voice: .hackerNews, maxTitleLength: 80, maxBodyLength: 500),
    ]

    static func preset(slug: String) -> PromotionChannel? {
        presets.first { $0.slug == slug.lowercased() }
    }

    /// 按平台名（大小写不敏感、slug 或显示名）找预设。
    static func preset(platform: String) -> PromotionChannel? {
        let q = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return presets.first { $0.slug == q || $0.platform.lowercased() == q }
    }
}
