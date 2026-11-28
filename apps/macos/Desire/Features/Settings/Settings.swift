import AppKit
import Combine
import Foundation

@MainActor
class Settings: ObservableObject {
    @Published var searchEngine: SearchEngine {
        didSet { AppPrefs.defaults.set(searchEngine.rawValue, forKey: "searchEngine") }
    }
    @Published var homePage: String {
        didSet { AppPrefs.defaults.set(homePage, forKey: "homePage") }
    }
    @Published var isJavaScriptEnabled: Bool {
        didSet { AppPrefs.defaults.set(isJavaScriptEnabled, forKey: "isJavaScriptEnabled") }
    }
    @Published var showSearchSuggestions: Bool {
        didSet { AppPrefs.defaults.set(showSearchSuggestions, forKey: "showSearchSuggestions") }
    }
    @Published var customEngines: [CustomSearchEngine] {
        didSet { saveCustomEngines() }
    }
    @Published var selectedCustomEngineId: UUID? {
        didSet { AppPrefs.defaults.set(selectedCustomEngineId?.uuidString, forKey: "selectedCustomEngineId") }
    }
    @Published var httpsUpgradeEnabled: Bool {
        didSet { AppPrefs.defaults.set(httpsUpgradeEnabled, forKey: "httpsUpgradeEnabled") }
    }
    /// 严格 HTTPS-only（v0.8.80）：升级失败不再自动回退 HTTP，停在错误页由用户决定。
    @Published var httpsOnlyMode: Bool {
        didSet { AppPrefs.defaults.set(httpsOnlyMode, forKey: "httpsOnlyMode") }
    }
    @Published var showLinkPreview: Bool {
        didSet { AppPrefs.defaults.set(showLinkPreview, forKey: "showLinkPreview") }
    }
    @Published var appearanceTheme: AppearanceTheme {
        didSet { AppPrefs.defaults.set(appearanceTheme.rawValue, forKey: "appearanceTheme") }
    }
    @Published var accentColor: AccentColor {
        didSet {
            AppPrefs.defaults.set(accentColor.rawValue, forKey: "accentColor")
            // 全局镜像：给拿不到 Settings 的窗口（插件窗、截图工具条）读。
            AppAccent.current = accentColor.color
        }
    }
    @Published var newTabPosition: NewTabPosition {
        didSet { AppPrefs.defaults.set(newTabPosition.rawValue, forKey: "newTabPosition") }
    }
    @Published var confirmCloseMultipleTabs: Bool {
        didSet { AppPrefs.defaults.set(confirmCloseMultipleTabs, forKey: "confirmCloseMultipleTabs") }
    }
    /// YouTube 赞助商片段跳过（SponsorBlock 社区数据）。注入发生在页面
    /// didFinish 时，切换对下一个页面加载生效。
    @Published var sponsorBlockSkip: Bool {
        didSet { AppPrefs.defaults.set(sponsorBlockSkip, forKey: "sponsorBlockSkip") }
    }
    /// 类别组：赞助商+自我推广（SponsorBlock 默认跳过项）。
    @Published var sponsorSkipMain: Bool {
        didSet { AppPrefs.defaults.set(sponsorSkipMain, forKey: "sponsorSkipMain") }
    }
    /// 类别组：片头/片尾/预览回顾。
    @Published var sponsorSkipChapters: Bool {
        didSet { AppPrefs.defaults.set(sponsorSkipChapters, forKey: "sponsorSkipChapters") }
    }
    /// 类别组：灌水/无关内容。
    @Published var sponsorSkipFiller: Bool {
        didSet { AppPrefs.defaults.set(sponsorSkipFiller, forKey: "sponsorSkipFiller") }
    }
    /// 当前启用的 SponsorBlock 类别（注入脚本消费）。
    var sponsorCategories: [String] {
        var categories: [String] = []
        if sponsorSkipMain { categories += ["sponsor", "selfpromo", "interaction"] }
        if sponsorSkipChapters { categories += ["intro", "outro", "preview"] }
        if sponsorSkipFiller { categories += ["filler"] }
        return categories
    }
    /// 常驻书签栏可见性（View 菜单 / 设置切换）。
    @Published var showBookmarksBar: Bool {
        didSet { AppPrefs.defaults.set(showBookmarksBar, forKey: "showBookmarksBar") }
    }
    /// 下载完成系统通知（批量聚合为一条）。DownloadStore 直读 UserDefaults，
    /// 与 suspendAfterMinutes 同款模式——改设置即时生效。
    @Published var downloadNotifications: Bool {
        didSet { AppPrefs.defaults.set(downloadNotifications, forKey: "downloadNotifications") }
    }
    /// 下载进行中在 Dock 图标上显示数量角标。
    @Published var downloadDockBadge: Bool {
        didSet { AppPrefs.defaults.set(downloadDockBadge, forKey: "downloadDockBadge") }
    }
    /// 每次下载完成时弹出保存面板选位置（关 = 直接进下载文件夹）。
    @Published var askWhereToSaveDownloads: Bool {
        didSet { AppPrefs.defaults.set(askWhereToSaveDownloads, forKey: "askWhereToSaveDownloads") }
    }
    /// 新标签的默认页面缩放（0.5–2.0）。BrowserState 初始化时直读
    /// UserDefaults 同名 key。
    @Published var defaultPageZoom: Double {
        didSet { AppPrefs.defaults.set(defaultPageZoom, forKey: "defaultPageZoom") }
    }
    /// 网页最小字号（px，0 = 关闭）。站点无显式覆盖时生效——
    /// SiteSettingsStore.effectiveFont 直读 UserDefaults 同名 key。
    @Published var defaultMinFontSize: Int {
        didSet { AppPrefs.defaults.set(defaultMinFontSize, forKey: "defaultMinFontSize") }
    }
    /// 网页默认字体族（空 = 不覆盖）。同 defaultMinFontSize。
    @Published var defaultFontFamily: String {
        didSet { AppPrefs.defaults.set(defaultFontFamily, forKey: "defaultFontFamily") }
    }

    /// 下载完成自动摘要（v0.8.15 替人干活，opt-in 默认关）：pdf/docx 等
    /// 文档完成后旁路一句话摘要进通知。
    @Published var downloadAutoSummarize: Bool {
        didSet { AppPrefs.defaults.set(downloadAutoSummarize, forKey: "downloadAutoSummarize") }
    }

    /// 定时任务失败自动重试次数（v0.8.16 替人干活：1-3，默认 1；
    /// 重试间隔指数退避 30s 起）。
    @Published var scheduledTaskRetries: Int {
        didSet { AppPrefs.defaults.set(scheduledTaskRetries, forKey: "scheduledTaskRetries") }
    }
    /// 高危文件类型（.dmg/.pkg/.sh 等）下载前弹确认。WebView 决策点直读
    /// UserDefaults，改动即时生效。
    @Published var warnDangerousDownloads: Bool {
        didSet { AppPrefs.defaults.set(warnDangerousDownloads, forKey: "warnDangerousDownloads") }
    }
    @Published var startupBehavior: StartupBehavior {
        didSet { AppPrefs.defaults.set(startupBehavior.rawValue, forKey: "startupBehavior") }
    }
    /// 「打开指定页集」的 URL 列表（空白/换行分隔；本机设置，刻意不进同步目录）。
    @Published var startupPageSet: String {
        didSet { AppPrefs.defaults.set(startupPageSet, forKey: "startupPageSet") }
    }
    /// 多窗口恢复策略（v0.8.52）：全部窗口 / 仅上次活跃窗口 / 不恢复。
    /// 只在启动行为为「恢复上次会话」时生效。
    @Published var windowRestoreMode: WindowRestoreMode {
        didSet { AppPrefs.defaults.set(windowRestoreMode.rawValue, forKey: "windowRestoreMode") }
    }
    @Published var autoPlayPolicy: AutoPlayPolicy {
        didSet { AppPrefs.defaults.set(autoPlayPolicy.rawValue, forKey: "autoPlayPolicy") }
    }
    /// Idle minutes before background tabs are suspended. `-1` disables
    /// suspension entirely. Persisted under the SAME key `TabManager` reads
    /// each sweep, so changes apply live without a restart.
    @Published var suspendAfterMinutes: Double {
        didSet { AppPrefs.defaults.set(suspendAfterMinutes, forKey: "suspendAfterMinutes") }
    }
    /// 链接"在后台打开"（⌘点击/中键开新标签不切换；0.6.3）。
    @Published var openLinksInBackground: Bool {
        didSet { AppPrefs.defaults.set(openLinksInBackground, forKey: "openLinksInBackground") }
    }
    /// 垂直标签栏（0.6.3）：侧栏形态替代顶部标签栏。
    @Published var verticalTabBar: Bool {
        didSet { AppPrefs.defaults.set(verticalTabBar, forKey: "verticalTabBar") }
    }
    /// 大页面守护（0.6.4）：后台标签 DOM 节点超阈值（25k）自动挂起。
    @Published var largePageGuard: Bool {
        didSet { AppPrefs.defaults.set(largePageGuard, forKey: "largePageGuard") }
    }
    /// 内存管家预算（v0.8.84 批 3 第 14 件）：后台标签 DOM 节点**总量**超过
    /// 该值时按"重量 × 最久未看"逐个挂起最重的（豁免集与挂起 sweep 一致）。
    /// 0 = 关闭管家。默认 60000（≈ 单标签守护阈值的 2.4 倍总量）。
    @Published var tabMemoryBudgetNodes: Int {
        didSet { AppPrefs.defaults.set(tabMemoryBudgetNodes, forKey: "tabMemoryBudgetNodes") }
    }
    /// Cookie 弹窗自动处理（0.6.5）：off | reject | accept（默认 off）。
    @Published var cookieBannerPolicy: String {
        didSet { AppPrefs.defaults.set(cookieBannerPolicy, forKey: "cookieBannerPolicy") }
    }
    @Published private(set) var screenshotFolder: URL {
        didSet { AppPrefs.defaults.set(screenshotFolder.path, forKey: "desire.screenshotFolder.path") }
    }

    private let customEnginesKey = "desire.customSearchEngines"
    private let screenshotBookmarkKey = "desire.screenshotFolder.bookmark"
    private var screenshotAccessedURL: URL?

    init() {
        searchEngine = SearchEngine(rawValue: AppPrefs.defaults.string(forKey: "searchEngine") ?? "") ?? .google
        homePage = AppPrefs.defaults.string(forKey: "homePage") ?? "https://www.google.com"
        isJavaScriptEnabled = AppPrefs.defaults.object(forKey: "isJavaScriptEnabled") as? Bool ?? true
        showSearchSuggestions = AppPrefs.defaults.object(forKey: "showSearchSuggestions") as? Bool ?? false
        httpsUpgradeEnabled = AppPrefs.defaults.object(forKey: "httpsUpgradeEnabled") as? Bool ?? true
        httpsOnlyMode = AppPrefs.defaults.object(forKey: "httpsOnlyMode") as? Bool ?? false
        showLinkPreview = AppPrefs.defaults.object(forKey: "showLinkPreview") as? Bool ?? false
        appearanceTheme = AppearanceTheme(rawValue: AppPrefs.defaults.string(forKey: "appearanceTheme") ?? "") ?? .system
        accentColor = AccentColor(rawValue: AppPrefs.defaults.string(forKey: "accentColor") ?? "") ?? .blue
        newTabPosition = NewTabPosition(rawValue: AppPrefs.defaults.string(forKey: "newTabPosition") ?? "") ?? .end
        confirmCloseMultipleTabs = AppPrefs.defaults.object(forKey: "confirmCloseMultipleTabs") as? Bool ?? true
        sponsorBlockSkip = AppPrefs.defaults.object(forKey: "sponsorBlockSkip") as? Bool ?? true
        sponsorSkipMain = AppPrefs.defaults.object(forKey: "sponsorSkipMain") as? Bool ?? true
        sponsorSkipChapters = AppPrefs.defaults.object(forKey: "sponsorSkipChapters") as? Bool ?? false
        sponsorSkipFiller = AppPrefs.defaults.object(forKey: "sponsorSkipFiller") as? Bool ?? false
        showBookmarksBar = AppPrefs.defaults.object(forKey: "showBookmarksBar") as? Bool ?? true
        downloadNotifications = AppPrefs.defaults.object(forKey: "downloadNotifications") as? Bool ?? true
        downloadDockBadge = AppPrefs.defaults.object(forKey: "downloadDockBadge") as? Bool ?? true
        askWhereToSaveDownloads = AppPrefs.defaults.object(forKey: "askWhereToSaveDownloads") as? Bool ?? false
        defaultPageZoom = AppPrefs.defaults.object(forKey: "defaultPageZoom") as? Double ?? 1.0
        downloadAutoSummarize = AppPrefs.defaults.bool(forKey: "downloadAutoSummarize")
        scheduledTaskRetries = {
            let raw = AppPrefs.defaults.integer(forKey: "scheduledTaskRetries")
            return (1...3).contains(raw) ? raw : 1
        }()
        defaultMinFontSize = AppPrefs.defaults.object(forKey: "defaultMinFontSize") as? Int ?? 0
        defaultFontFamily = AppPrefs.defaults.string(forKey: "defaultFontFamily") ?? ""
        warnDangerousDownloads = AppPrefs.defaults.object(forKey: "warnDangerousDownloads") as? Bool ?? true
        startupBehavior = StartupBehavior(rawValue: AppPrefs.defaults.string(forKey: "startupBehavior") ?? "") ?? .restoreSession
        startupPageSet = AppPrefs.defaults.string(forKey: "startupPageSet") ?? ""
        windowRestoreMode = WindowRestoreMode(rawValue: AppPrefs.defaults.string(forKey: "windowRestoreMode") ?? "") ?? .all
        autoPlayPolicy = AutoPlayPolicy(rawValue: AppPrefs.defaults.string(forKey: "autoPlayPolicy") ?? "") ?? .requireUserAction
        suspendAfterMinutes = AppPrefs.defaults.object(forKey: "suspendAfterMinutes") as? Double ?? 30
        openLinksInBackground = AppPrefs.defaults.bool(forKey: "openLinksInBackground")
        verticalTabBar = AppPrefs.defaults.bool(forKey: "verticalTabBar")
        largePageGuard = AppPrefs.defaults.object(forKey: "largePageGuard") as? Bool ?? true
        tabMemoryBudgetNodes = AppPrefs.defaults.object(forKey: "tabMemoryBudgetNodes") as? Int ?? 60_000
        cookieBannerPolicy = AppPrefs.defaults.string(forKey: "cookieBannerPolicy") ?? "off"

        // Screenshot folder: resolve from bookmark first, else fall back to
        // the persisted path, else to the default Pictures directory. Must be
        // initialized before any `self.` access below (e.g. customEngines).
        var resolvedFolder = Settings.defaultScreenshotFolder()
        if let bookmark = Settings.resolveBookmark(bookmarkKey: screenshotBookmarkKey) {
            resolvedFolder = bookmark.url
            if bookmark.url.startAccessingSecurityScopedResource() {
                screenshotAccessedURL = bookmark.url
            }
        } else if let path = AppPrefs.defaults.string(forKey: "desire.screenshotFolder.path") {
            let url = URL(fileURLWithPath: path)
            // Try to start security scope (works if path lives under a sandbox-
            // accessible standard directory like Pictures).
            if url.startAccessingSecurityScopedResource() {
                screenshotAccessedURL = url
            }
            resolvedFolder = url
        }
        screenshotFolder = resolvedFolder

        customEngines = Settings.loadCustomEngines(key: customEnginesKey)
        if let idStr = AppPrefs.defaults.string(forKey: "selectedCustomEngineId"),
           let id = UUID(uuidString: idStr) {
            selectedCustomEngineId = customEngines.contains(where: { $0.id == id }) ? id : nil
        } else {
            selectedCustomEngineId = nil
        }
        // 初次读取也要同步镜像：didSet 在 init 里不触发，否则插件窗/
        // 截图工具条（读 AppAccent.current）会一直用默认蓝。
        AppAccent.current = accentColor.color
    }

    var searchURLTemplate: String {
        if let id = selectedCustomEngineId,
           let engine = customEngines.first(where: { $0.id == id }) {
            return engine.searchURL
        }
        return searchEngine.searchURL
    }

    /// Suggestion endpoint of the engine that would ACTUALLY be used, or
    /// nil when that engine has none. Deliberately no fallback to the
    /// built-in engine's endpoint — silently sending queries typed under a
    /// custom engine to another provider is a privacy leak.
    var effectiveSuggestionURL: String? {
        if let id = selectedCustomEngineId,
           let engine = customEngines.first(where: { $0.id == id }) {
            return engine.suggestionURL.isEmpty ? nil : engine.suggestionURL
        }
        return searchEngine.suggestionURL
    }

    /// Display name of the engine currently in effect (custom wins over
    /// built-in). Used by the toolbar engine menu and the suggestion rows.
    var effectiveEngineName: String {
        URLResolution.defaultTarget(self).displayName
    }

    func addCustomEngine(name: String, searchURL: String, suggestionURL: String, keyword: String? = nil) {
        let engine = CustomSearchEngine(id: UUID(), name: name, searchURL: searchURL, suggestionURL: suggestionURL, keyword: keyword)
        customEngines.append(engine)
    }

    func removeCustomEngine(_ id: UUID) {
        customEngines.removeAll { $0.id == id }
    }

    private func saveCustomEngines() {
        DiskStore.save(customEngines, key: customEnginesKey)
    }

    private static func loadCustomEngines(key: String) -> [CustomSearchEngine] {
        if let engines = DiskStore.load([CustomSearchEngine].self, key: key) {
            return engines
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = AppPrefs.defaults.data(forKey: key),
           let engines = try? JSONDecoder().decode([CustomSearchEngine].self, from: data) {
            DiskStore.save(engines, key: key)
            AppPrefs.defaults.removeObject(forKey: key)
            return engines
        }
        return []
    }

    // MARK: - Screenshot folder

    /// Default screenshot save location: the user's Pictures directory.
    static func defaultScreenshotFolder() -> URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
    }

    private static func resolveBookmark(bookmarkKey: String) -> (url: URL, data: Data)? {
        guard let data = AppPrefs.defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale {
            if let refreshed = try? url.bookmarkData(options: [.withSecurityScope]) {
                AppPrefs.defaults.set(refreshed, forKey: bookmarkKey)
            }
        }
        return (url, data)
    }

    /// Open an NSOpenPanel to pick a new screenshot folder. Persists a security-
    /// scoped bookmark so the choice survives relaunches.
    @discardableResult
    func chooseScreenshotFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = screenshotFolder
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        if url.startAccessingSecurityScopedResource() {
            if let data = try? url.bookmarkData(options: [.withSecurityScope]) {
                AppPrefs.defaults.set(data, forKey: screenshotBookmarkKey)
            }
            screenshotAccessedURL?.stopAccessingSecurityScopedResource()
            screenshotAccessedURL = url
        }
        screenshotFolder = url
        return true
    }

    /// Reset to the default Pictures folder and discard any persisted bookmark.
    func resetScreenshotFolder() {
        screenshotAccessedURL?.stopAccessingSecurityScopedResource()
        screenshotAccessedURL = nil
        AppPrefs.defaults.removeObject(forKey: screenshotBookmarkKey)
        AppPrefs.defaults.removeObject(forKey: "desire.screenshotFolder.path")
        screenshotFolder = Settings.defaultScreenshotFolder()
    }

    /// A unique URL inside `screenshotFolder` for the given filename, appending
    /// " 2", " 3", … when a file with the same name already exists.
    func uniqueScreenshotURL(for filename: String) -> URL {
        let base = screenshotFolder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = screenshotFolder.appendingPathComponent(candidateName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
            i += 1
        }
    }
}
