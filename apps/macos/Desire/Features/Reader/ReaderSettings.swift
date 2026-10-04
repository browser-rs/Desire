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

    func save() {
        let d = UserDefaults.standard
        d.set(fontSize, forKey: "reader.fontSize")
        d.set(theme.rawValue, forKey: "reader.theme")
        d.set(lineSpacing, forKey: "reader.lineSpacing")
    }
}
