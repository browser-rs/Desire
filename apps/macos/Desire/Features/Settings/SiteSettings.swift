import Foundation

/// Per-site settings persisted by `SiteSettingsStore` (zoom level, dark-mode
/// override, blocked CSS selectors for a given host).
struct SiteSettings: Codable {
    var zoom: Double
    var darkMode: Bool = false
    var blockedSelectors: [String] = []
    /// 按站点的自动播放覆写（nil = 跟随全局 `autoPlayPolicy`）。全局默认档
    /// "需要用户手势"会拦住**新文档**的自动播放——YouTube 直开链接/外链新
    /// 标签不播（页面内点缩略图有激活所以能播，这就是"时好时坏"的来源）。
    /// 视频站在站点粒度豁免/收紧，WebView 每次主框架导航按目标 host 查这
    /// 里覆写导航偏好（Safari/Chrome 的按站点"允许自动播放"同款语义）。
    enum AutoPlay: String, Codable {
        case allow
        case block
    }
    var autoPlay: AutoPlay?
}
