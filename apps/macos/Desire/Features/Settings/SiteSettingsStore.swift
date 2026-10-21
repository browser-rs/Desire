import Combine
import Foundation

@MainActor
class SiteSettingsStore: ObservableObject {
    @Published private var settings: [String: SiteSettings] = [:]

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let key = "desire.siteSettings"

    init() {
        if let decoded = DiskStore.load([String: SiteSettings].self, key: key) {
            settings = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: SiteSettings].self, from: data) {
            settings = decoded
            save()
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func zoom(for domain: String) -> Double {
        // P1-9：无站点记录时兜底"默认页面缩放"设置——此前字面量 1.0，
        // didCommit 每次导航都用它覆盖，设置里的默认缩放形同虚设。
        settings[domain]?.zoom
            ?? UserDefaults.standard.object(forKey: "defaultPageZoom") as? Double
            ?? 1.0
    }

    func setZoom(_ zoom: Double, for domain: String) {
        if zoom == 1.0 {
            settings[domain]?.zoom = 1.0
            cleanEmpty(domain)
        } else {
            var s = settings[domain] ?? SiteSettings(zoom: 1.0)
            s.zoom = zoom
            settings[domain] = s
        }
        save()
    }

    func darkModeEnabled(for domain: String) -> Bool {
        settings[domain]?.darkMode ?? false
    }

    func setDarkMode(_ enabled: Bool, for domain: String) {
        if enabled {
            var s = settings[domain] ?? SiteSettings(zoom: 1.0)
            s.darkMode = true
            settings[domain] = s
        } else {
            settings[domain]?.darkMode = false
            cleanEmpty(domain)
        }
        save()
        objectWillChange.send()
    }

    func blockedSelectors(for domain: String) -> [String] {
        settings[domain]?.blockedSelectors ?? []
    }

    /// 该站点的自动播放覆写（nil = 跟随全局 / 视频平台默认）。
    func autoPlayOverride(for domain: String) -> SiteSettings.AutoPlay? {
        settings[domain]?.autoPlay
    }

    /// 该站点上**生效**的自动播放档位（覆写 > 视频平台默认 > 全局）。
    /// 菜单勾选态与重开标签都走这一处，避免"显示 Off 实际却允许"的错位。
    func effectiveAutoPlay(for domain: String, global: AutoPlayPolicy) -> AutoPlayPolicy {
        .resolved(global: global, host: domain,
                  siteOverrideRaw: autoPlayOverride(for: domain)?.rawValue)
    }

    func isAutoPlayAllowed(for domain: String, global: AutoPlayPolicy) -> Bool {
        effectiveAutoPlay(for: domain, global: global) == .allowAll
    }

    // MARK: - 站点字体（最小字号 + 字体族）

    /// 该站点**生效**的字体设置：站点显式值优先，未设跟随全局默认
    /// （`defaultMinFontSize` / `defaultFontFamily`，设置页写入）。
    func effectiveFont(for domain: String) -> SiteFont {
        let global = defaultFont
        return SiteFont.resolve(
            siteMin: settings[domain]?.minFontSize,
            siteFamily: settings[domain]?.fontFamily,
            defaultMin: global.minFontSize,
            defaultFamily: global.fontFamily
        )
    }

    /// 全局默认（设置页两键的直读）。
    var defaultFont: SiteFont {
        let defaults = UserDefaults.standard
        return SiteFont.resolve(
            siteMin: nil,
            siteFamily: nil,
            defaultMin: defaults.object(forKey: "defaultMinFontSize") as? Int ?? 0,
            defaultFamily: defaults.string(forKey: "defaultFontFamily") ?? ""
        )
    }

    /// 站点显式值（nil = 跟随默认）——站点弹层回显用。
    func fontOverride(for domain: String) -> (min: Int?, family: String?) {
        (settings[domain]?.minFontSize, settings[domain]?.fontFamily)
    }

    /// `value`：nil = 跟随全局；0 = 本站关闭；9–24 = 生效值（越界夹取）。
    func setMinFontSize(_ value: Int?, for domain: String) {
        guard var s = settings[domain] ?? (value == nil ? nil : SiteSettings(zoom: 1.0)) else { return }
        s.minFontSize = value.map { SiteFont.clampMin($0) }
        settings[domain] = s
        cleanEmpty(domain)
        save()
        objectWillChange.send()
    }

    /// `value`：nil = 跟随全局；空串 = 本站不覆盖；其余为字体族名。
    func setFontFamily(_ value: String?, for domain: String) {
        guard var s = settings[domain] ?? (value == nil ? nil : SiteSettings(zoom: 1.0)) else { return }
        s.fontFamily = value.map { SiteFont.clampFamily($0) }
        settings[domain] = s
        cleanEmpty(domain)
        save()
        objectWillChange.send()
    }

    func setAutoPlay(_ mode: SiteSettings.AutoPlay?, for domain: String) {
        // mode == nil 且站点本来就没记录 → 无事可做（别凭空造一条空记录）。
        guard var s = settings[domain] ?? (mode == nil ? nil : SiteSettings(zoom: 1.0)) else { return }
        s.autoPlay = mode
        settings[domain] = s
        cleanEmpty(domain)
        save()
        objectWillChange.send()
    }

    func addBlockedSelector(_ selector: String, for domain: String) {
        var s = settings[domain] ?? SiteSettings(zoom: 1.0)
        if !s.blockedSelectors.contains(selector) {
            s.blockedSelectors.append(selector)
            settings[domain] = s
            save()
            objectWillChange.send()
        }
    }

    func removeBlockedSelector(_ selector: String, for domain: String) {
        settings[domain]?.blockedSelectors.removeAll { $0 == selector }
        cleanEmpty(domain)
        save()
        objectWillChange.send()
    }

    /// 清除本站全部 UI 覆盖（缩放之外：暗色/自动播放/字体；**拦截规则
    /// 不动**——那是内容级决定，走拦截面板单独管理）。缩放由调用方走
    /// setZoom(1.0) 保持"记站点"同一条路径。UI（站点控制中心）与桥
    /// `/site-settings/clear` 共用。
    func clearOverrides(for domain: String) {
        guard settings[domain] != nil else { return }
        settings[domain]?.darkMode = false
        settings[domain]?.autoPlay = nil
        settings[domain]?.minFontSize = nil
        settings[domain]?.fontFamily = nil
        cleanEmpty(domain)
        save()
        objectWillChange.send()
    }

    func resetAll() {
        settings.removeAll()
        save()
    }

    private func cleanEmpty(_ domain: String) {
        if let s = settings[domain], s.zoom == 1.0, !s.darkMode, s.blockedSelectors.isEmpty,
           s.autoPlay == nil, s.minFontSize == nil, s.fontFamily == nil {
            settings.removeValue(forKey: domain)
        }
    }

    private func save() {
        DiskStore.save(settings, key: key)
    }
}
