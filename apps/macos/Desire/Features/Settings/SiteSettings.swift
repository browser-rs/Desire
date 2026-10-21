import Foundation

/// Per-site settings persisted by `SiteSettingsStore` (zoom level, dark-mode
/// override, blocked CSS selectors for a given host).
struct SiteSettings: Codable {
    var zoom: Double
    var darkMode: Bool = false
    var blockedSelectors: [String] = []
    /// 按站点的自动播放覆写（nil = 跟随全局 `autoPlayPolicy`；视频平台在
    /// "需要用户手势"档下另有默认豁免，见 `AutoPlayPolicy.isVideoHost`）。
    /// 全局默认档会拦住**新文档**的自动播放——YouTube 直开链接/外链新标签
    /// 不播（页面内点缩略图有激活所以能播，这就是"时好时坏"的来源）。
    /// 站点粒度可豁免（allow）或收紧（block）；WebView 在创建期按目标 host
    /// 解析生效档位（Safari/Chrome 的按站点"允许自动播放"同款语义）。
    enum AutoPlay: String, Codable {
        case allow
        case block
    }
    var autoPlay: AutoPlay?
    /// 站点级最小字号（px，0 = 本站关闭；nil = 跟随全局 `defaultMinFontSize`）。
    var minFontSize: Int?
    /// 站点级字体族（空串 = 本站不覆盖；nil = 跟随全局 `defaultFontFamily`）。
    var fontFamily: String?
}
