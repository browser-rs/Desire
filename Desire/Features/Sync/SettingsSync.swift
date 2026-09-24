import AppKit
import Foundation

/// 设置 KV 域的同步目录：哪些键可同步、怎么读、怎么写回。
/// client_id = UserDefaults 键名；载荷 = SettingsSyncValue（值本体）。
/// **刻意排除机器相关/本地引用项**：screenshotFolder（本机路径）、
/// selectedCustomEngineId（引用本机 customEngines，单独同步会悬空）。
/// LWW 语义：设置没有 per-key updatedAt——由 SyncStore 维护
/// "快照 diff 检测本地变更 → 变更盖新戳"，详见 SyncStore.collectSettings。
struct SettingsSyncEntry {
    let key: String
    let read: (Settings) -> SettingsSyncValue?
    /// 返回 false = 值非法（如枚举 rawValue 不认识），调用方不得记快照
    let apply: (Settings, SettingsSyncValue) -> Bool
}

enum SettingsSync {

    static let catalog: [SettingsSyncEntry] = [
        rawEnum("searchEngine", { $0.searchEngine }, { s, v in s.searchEngine = v }),
        text("homePage", { $0.homePage }, { s, v in s.homePage = v }),
        flag("isJavaScriptEnabled", { $0.isJavaScriptEnabled }, { s, v in s.isJavaScriptEnabled = v }),
        flag("showSearchSuggestions", { $0.showSearchSuggestions }, { s, v in s.showSearchSuggestions = v }),
        flag("httpsUpgradeEnabled", { $0.httpsUpgradeEnabled }, { s, v in s.httpsUpgradeEnabled = v }),
        flag("showLinkPreview", { $0.showLinkPreview }, { s, v in s.showLinkPreview = v }),
        rawEnum("appearanceTheme", { $0.appearanceTheme }, { s, v in s.appearanceTheme = v }),
        rawEnum("accentColor", { $0.accentColor }, { s, v in s.accentColor = v }),
        rawEnum("newTabPosition", { $0.newTabPosition }, { s, v in s.newTabPosition = v }),
        flag("confirmCloseMultipleTabs", { $0.confirmCloseMultipleTabs }, { s, v in s.confirmCloseMultipleTabs = v }),
        flag("sponsorBlockSkip", { $0.sponsorBlockSkip }, { s, v in s.sponsorBlockSkip = v }),
        flag("sponsorSkipMain", { $0.sponsorSkipMain }, { s, v in s.sponsorSkipMain = v }),
        flag("sponsorSkipChapters", { $0.sponsorSkipChapters }, { s, v in s.sponsorSkipChapters = v }),
        flag("sponsorSkipFiller", { $0.sponsorSkipFiller }, { s, v in s.sponsorSkipFiller = v }),
        flag("showBookmarksBar", { $0.showBookmarksBar }, { s, v in s.showBookmarksBar = v }),
        flag("downloadNotifications", { $0.downloadNotifications }, { s, v in s.downloadNotifications = v }),
        flag("downloadDockBadge", { $0.downloadDockBadge }, { s, v in s.downloadDockBadge = v }),
        flag("askWhereToSaveDownloads", { $0.askWhereToSaveDownloads }, { s, v in s.askWhereToSaveDownloads = v }),
        number("defaultPageZoom", { $0.defaultPageZoom }, { s, v in s.defaultPageZoom = v }),
        flag("warnDangerousDownloads", { $0.warnDangerousDownloads }, { s, v in s.warnDangerousDownloads = v }),
        rawEnum("startupBehavior", { $0.startupBehavior }, { s, v in s.startupBehavior = v }),
        rawEnum("autoPlayPolicy", { $0.autoPlayPolicy }, { s, v in s.autoPlayPolicy = v }),
        number("suspendAfterMinutes", { $0.suspendAfterMinutes }, { s, v in s.suspendAfterMinutes = v }),
    ]

    static func entry(forKey key: String) -> SettingsSyncEntry? {
        catalog.first { $0.key == key }
    }

    // MARK: - 目录构造器

    private static func text(
        _ key: String, _ get: @escaping (Settings) -> String, _ set: @escaping (Settings, String) -> Void
    ) -> SettingsSyncEntry {
        SettingsSyncEntry(key: key,
            read: { .string(get($0)) },
            apply: { s, v in
                guard case .string(let value) = v else { return false }
                set(s, value); return true
            })
    }

    private static func flag(
        _ key: String, _ get: @escaping (Settings) -> Bool, _ set: @escaping (Settings, Bool) -> Void
    ) -> SettingsSyncEntry {
        SettingsSyncEntry(key: key,
            read: { .bool(get($0)) },
            apply: { s, v in
                guard case .bool(let value) = v else { return false }
                set(s, value); return true
            })
    }

    private static func number(
        _ key: String, _ get: @escaping (Settings) -> Double, _ set: @escaping (Settings, Double) -> Void
    ) -> SettingsSyncEntry {
        SettingsSyncEntry(key: key,
            read: { .number(get($0)) },
            apply: { s, v in
                guard case .number(let value) = v else { return false }
                set(s, value); return true
            })
    }

    /// rawValue 为 String 的枚举偏好；远端值非法时拒绝（不记快照，不吞本地值）。
    private static func rawEnum<E: RawRepresentable>(
        _ key: String, _ get: @escaping (Settings) -> E, _ set: @escaping (Settings, E) -> Void
    ) -> SettingsSyncEntry where E.RawValue == String {
        SettingsSyncEntry(key: key,
            read: { .string(get($0).rawValue) },
            apply: { s, v in
                guard case .string(let raw) = v, let value = E(rawValue: raw) else { return false }
                set(s, value); return true
            })
    }
}
