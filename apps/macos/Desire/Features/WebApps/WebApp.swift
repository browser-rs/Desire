import Foundation

/// 网页应用（App Mode，v0.8.0）：把一个站点装成独立窗口。
///
/// **不是 Dock 级的 .app bundle**（本版范围）：窗口无地址栏/标签栏，使用独立
/// `WKWebsiteDataStore`（或共享主浏览器登录），由 Web Apps 管理器打开/卸载。
nonisolated struct WebApp: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var startURL: String
    var host: String
    /// true = 与主浏览器共享 cookies/登录；false = 独立 data store。
    var shareSession: Bool
    var createdAt: Date
    /// 上次停留的页面（v0.8.1）：再次打开时回到这里。Optional + 合成 Codable
    /// = 旧文件缺键解码为 nil，不丢数据。
    var lastURL: String? = nil
    var lastVisitedAt: Date? = nil

    /// 恢复地址：只接受**本应用域名（含子域）**的页面——登录跳到第三方
    /// OAuth 页时不要把窗口恢复到那个一次性地址。
    var resumeURL: String? {
        guard let raw = lastURL, let url = URL(string: raw),
              let lastHost = url.host?.lowercased(), !lastHost.isEmpty else { return nil }
        let scope = host.lowercased()
        guard lastHost == scope || lastHost.hasSuffix("." + scope) else { return nil }
        return raw
    }

    static func make(url: URL, name: String?, shareSession: Bool) -> WebApp? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return WebApp(id: UUID(),
                      name: trimmed.isEmpty ? host : trimmed,
                      startURL: url.absoluteString,
                      host: host,
                      shareSession: shareSession,
                      createdAt: Date())
    }
}

extension Notification.Name {
    /// 桥/深链请求打开某个 Web App 窗口（ContentView 持有 openWindow 环境）。
    static let openWebApp = Notification.Name("desire.webApp.open")
    /// 卸载时关闭对应窗口（WebAppWindowView 持有 dismissWindow 环境）。
    static let closeWebApp = Notification.Name("desire.webApp.close")
}
