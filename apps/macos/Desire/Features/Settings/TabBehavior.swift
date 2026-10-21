import Foundation

enum NewTabPosition: String, CaseIterable, Codable {
    case end
    case afterCurrent
}

enum StartupBehavior: String, CaseIterable, Codable {
    /// 继续上次会话（默认；采纳 index 里最近的会话）。
    case restoreSession
    /// 打开新标签页。
    case newTabPage
    /// 打开主页（Settings.homePage）。
    case homePage
    /// 打开指定页集（Settings.startupPageSet：空白/换行分隔的 URL 列表）。
    case pageSet
}

/// 启动页集的解析：空白/换行分隔 → 只保 http(s)、去重、封顶 10 条。
/// 纯逻辑（Foundation-only，进 tests/run.sh）——SessionRestore 与设置页
/// 校验共用，口径不会漂。
enum StartupPageSet {
    static let cap = 10

    static func urls(from raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for piece in raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let text = String(piece)
            guard let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else { continue }
            if seen.insert(text).inserted {
                out.append(text)
                if out.count >= cap { break }
            }
        }
        return out
    }
}

enum AutoPlayPolicy: String, CaseIterable, Codable {
    case allowAll
    case requireUserAction
    case never
}

extension AutoPlayPolicy {
    /// 视频平台站点（默认豁免"需要用户手势"）。
    ///
    /// 全局默认档 `requireUserAction` 对**新文档**一律拦自动播放；这在普通
    /// 网页上是对的，但在视频站上会得到一个"黑屏 + 播放键"的播放器——用户
    /// 打开视频详情页期待的是直接播放（2026-10-21 实测反馈）。Chrome 对高
    /// 互动站点有同类豁免；这里用显式名单，语义可预期。
    ///
    /// **不覆盖用户显式选择**：站点覆写 `.block` 优先；全局档选 `.never` 时
    /// 视频站也遵守。站点控制中心与工具栏菜单都能把单站改回阻断。
    nonisolated static func isVideoHost(_ host: String) -> Bool {
        let h = host.lowercased()
        guard !h.isEmpty else { return false }
        let markers = [
            "youtube.com", "youtube-nocookie.com", "youtu.be",
            "bilibili.com", "b23.tv",
            "v.qq.com", "iqiyi.com", "iq.com", "youku.com", "mgtv.com",
            "vimeo.com", "dailymotion.com",
        ]
        return markers.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// 解析某 host 上**生效**的自动播放档位。
    /// 优先级：站点显式覆写（allow/block） > 视频平台默认豁免 > 全局档。
    nonisolated static func resolved(global: AutoPlayPolicy,
                                     host: String,
                                     siteOverrideRaw: String?) -> AutoPlayPolicy {
        if let raw = siteOverrideRaw {
            return raw == "allow" ? .allowAll : .never
        }
        if global == .requireUserAction, isVideoHost(host) { return .allowAll }
        return global
    }
}
