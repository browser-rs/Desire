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
