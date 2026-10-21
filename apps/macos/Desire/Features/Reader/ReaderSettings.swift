import Foundation

/// 阅读器设置（0.3.7）：字号/主题/行距，UserDefaults 持久化。
/// 从 ReaderView.swift 抽出——持久化不进 View 文件（ARCH-3）。
struct ReaderSettings {
    var fontSize: Int = 18
    var theme: Theme = .auto
    var lineSpacing: Double = 1.7

    enum Theme: String, CaseIterable, Identifiable {
        case auto, light, sepia, dark
        var id: String { rawValue }
    }

    static func load() -> ReaderSettings {
        let d = UserDefaults.standard
        return ReaderSettings(
            fontSize: d.object(forKey: "reader.fontSize") as? Int ?? 18,
            theme: Theme(rawValue: d.string(forKey: "reader.theme") ?? "") ?? .auto,
            lineSpacing: d.object(forKey: "reader.lineSpacing") as? Double ?? 1.7
        )
    }

    /// 站点级覆盖（v0.7.29）：没有覆盖时跟随全局。
    static func load(host: String?) -> ReaderSettings {
        var settings = load()
        guard let host, !host.isEmpty else { return settings }
        let prefix = "reader.site.\(host.lowercased())."
        let d = UserDefaults.standard
        if let size = d.object(forKey: prefix + "fontSize") as? Int { settings.fontSize = size }
        if let raw = d.string(forKey: prefix + "theme"),
           let theme = Theme(rawValue: raw) { settings.theme = theme }
        if let spacing = d.object(forKey: prefix + "lineSpacing") as? Double {
            settings.lineSpacing = spacing
        }
        return settings
    }

    func save() {
        let d = UserDefaults.standard
        d.set(fontSize, forKey: "reader.fontSize")
        d.set(theme.rawValue, forKey: "reader.theme")
        d.set(lineSpacing, forKey: "reader.lineSpacing")
    }

    /// 把当前设置钉在该站点（阅读模式工具栏"Remember for this site"）。
    func saveForSite(_ host: String?) {
        guard let host, !host.isEmpty else { return }
        let prefix = "reader.site.\(host.lowercased())."
        let d = UserDefaults.standard
        d.set(fontSize, forKey: prefix + "fontSize")
        d.set(theme.rawValue, forKey: prefix + "theme")
        d.set(lineSpacing, forKey: prefix + "lineSpacing")
    }

    static func clearSiteOverride(_ host: String?) {
        guard let host, !host.isEmpty else { return }
        let prefix = "reader.site.\(host.lowercased())."
        let d = UserDefaults.standard
        d.removeObject(forKey: prefix + "fontSize")
        d.removeObject(forKey: prefix + "theme")
        d.removeObject(forKey: prefix + "lineSpacing")
    }
}
