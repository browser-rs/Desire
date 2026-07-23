import AppKit
import Combine
import Foundation

@MainActor
class Settings: ObservableObject {
    @Published var searchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: "searchEngine") }
    }
    @Published var homePage: String {
        didSet { UserDefaults.standard.set(homePage, forKey: "homePage") }
    }
    @Published var isJavaScriptEnabled: Bool {
        didSet { UserDefaults.standard.set(isJavaScriptEnabled, forKey: "isJavaScriptEnabled") }
    }
    @Published var showSearchSuggestions: Bool {
        didSet { UserDefaults.standard.set(showSearchSuggestions, forKey: "showSearchSuggestions") }
    }
    @Published var customEngines: [CustomSearchEngine] {
        didSet { saveCustomEngines() }
    }
    @Published var selectedCustomEngineId: UUID? {
        didSet { UserDefaults.standard.set(selectedCustomEngineId?.uuidString, forKey: "selectedCustomEngineId") }
    }
    @Published var httpsUpgradeEnabled: Bool {
        didSet { UserDefaults.standard.set(httpsUpgradeEnabled, forKey: "httpsUpgradeEnabled") }
    }
    @Published var showLinkPreview: Bool {
        didSet { UserDefaults.standard.set(showLinkPreview, forKey: "showLinkPreview") }
    }
    @Published var appearanceTheme: AppearanceTheme {
        didSet { UserDefaults.standard.set(appearanceTheme.rawValue, forKey: "appearanceTheme") }
    }
    @Published var accentColor: AccentColor {
        didSet { UserDefaults.standard.set(accentColor.rawValue, forKey: "accentColor") }
    }
    @Published var newTabPosition: NewTabPosition {
        didSet { UserDefaults.standard.set(newTabPosition.rawValue, forKey: "newTabPosition") }
    }
    @Published var confirmCloseMultipleTabs: Bool {
        didSet { UserDefaults.standard.set(confirmCloseMultipleTabs, forKey: "confirmCloseMultipleTabs") }
    }
    @Published var startupBehavior: StartupBehavior {
        didSet { UserDefaults.standard.set(startupBehavior.rawValue, forKey: "startupBehavior") }
    }
    @Published var autoPlayPolicy: AutoPlayPolicy {
        didSet { UserDefaults.standard.set(autoPlayPolicy.rawValue, forKey: "autoPlayPolicy") }
    }
    @Published private(set) var screenshotFolder: URL {
        didSet { UserDefaults.standard.set(screenshotFolder.path, forKey: "desire.screenshotFolder.path") }
    }

    private let customEnginesKey = "desire.customSearchEngines"
    private let screenshotBookmarkKey = "desire.screenshotFolder.bookmark"
    private var screenshotAccessedURL: URL?

    init() {
        searchEngine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
        homePage = UserDefaults.standard.string(forKey: "homePage") ?? "https://www.google.com"
        isJavaScriptEnabled = UserDefaults.standard.object(forKey: "isJavaScriptEnabled") as? Bool ?? true
        showSearchSuggestions = UserDefaults.standard.object(forKey: "showSearchSuggestions") as? Bool ?? false
        httpsUpgradeEnabled = UserDefaults.standard.object(forKey: "httpsUpgradeEnabled") as? Bool ?? true
        showLinkPreview = UserDefaults.standard.object(forKey: "showLinkPreview") as? Bool ?? false
        appearanceTheme = AppearanceTheme(rawValue: UserDefaults.standard.string(forKey: "appearanceTheme") ?? "") ?? .system
        accentColor = AccentColor(rawValue: UserDefaults.standard.string(forKey: "accentColor") ?? "") ?? .blue
        newTabPosition = NewTabPosition(rawValue: UserDefaults.standard.string(forKey: "newTabPosition") ?? "") ?? .end
        confirmCloseMultipleTabs = UserDefaults.standard.object(forKey: "confirmCloseMultipleTabs") as? Bool ?? true
        startupBehavior = StartupBehavior(rawValue: UserDefaults.standard.string(forKey: "startupBehavior") ?? "") ?? .restoreSession
        autoPlayPolicy = AutoPlayPolicy(rawValue: UserDefaults.standard.string(forKey: "autoPlayPolicy") ?? "") ?? .requireUserAction

        // Screenshot folder: resolve from bookmark first, else fall back to
        // the persisted path, else to the default Pictures directory. Must be
        // initialized before any `self.` access below (e.g. customEngines).
        var resolvedFolder = Settings.defaultScreenshotFolder()
        if let bookmark = Settings.resolveBookmark(bookmarkKey: screenshotBookmarkKey) {
            resolvedFolder = bookmark.url
            if bookmark.url.startAccessingSecurityScopedResource() {
                screenshotAccessedURL = bookmark.url
            }
        } else if let path = UserDefaults.standard.string(forKey: "desire.screenshotFolder.path") {
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
        if let idStr = UserDefaults.standard.string(forKey: "selectedCustomEngineId"),
           let id = UUID(uuidString: idStr) {
            selectedCustomEngineId = customEngines.contains(where: { $0.id == id }) ? id : nil
        } else {
            selectedCustomEngineId = nil
        }
    }

    var searchURLTemplate: String {
        if let id = selectedCustomEngineId,
           let engine = customEngines.first(where: { $0.id == id }) {
            return engine.searchURL
        }
        return searchEngine.searchURL
    }

    var suggestionURLTemplate: String {
        if let id = selectedCustomEngineId,
           let engine = customEngines.first(where: { $0.id == id }),
           !engine.suggestionURL.isEmpty {
            return engine.suggestionURL
        }
        return searchEngine.suggestionURL
    }

    func addCustomEngine(name: String, searchURL: String, suggestionURL: String) {
        let engine = CustomSearchEngine(id: UUID(), name: name, searchURL: searchURL, suggestionURL: suggestionURL)
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
        if let data = UserDefaults.standard.data(forKey: key),
           let engines = try? JSONDecoder().decode([CustomSearchEngine].self, from: data) {
            DiskStore.save(engines, key: key)
            UserDefaults.standard.removeObject(forKey: key)
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
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale {
            if let refreshed = try? url.bookmarkData(options: [.withSecurityScope]) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
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
                UserDefaults.standard.set(data, forKey: screenshotBookmarkKey)
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
        UserDefaults.standard.removeObject(forKey: screenshotBookmarkKey)
        UserDefaults.standard.removeObject(forKey: "desire.screenshotFolder.path")
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
