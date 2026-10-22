import Foundation

/// 浏览器数据导入的检测/预览/落地（v0.8.0）。
///
/// 只读用户选中的浏览器档案；SQLite 先复制到临时目录再交给 `/usr/bin/sqlite3
/// -json`（原库常被浏览器锁住，且子进程不继承 App 的 TCC 授权）。密码不解
/// Chromium 的加密库，统一引导 CSV 导入。
enum BrowserImportService {
    // MARK: - 检测

    /// 标准安装位置里的档案（读不到 Safari 目录时它不会出现，用户可手动选）。
    static func detectedProfiles() -> [BrowserImportProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [(BrowserImportSource, URL)] = [
            (.chrome, home.appendingPathComponent("Library/Application Support/Google/Chrome")),
            (.edge, home.appendingPathComponent("Library/Application Support/Microsoft Edge")),
            (.brave, home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser")),
            (.arc, home.appendingPathComponent("Library/Application Support/Arc/User Data")),
        ]
        var out: [BrowserImportProfile] = []
        for (source, root) in roots {
            out.append(contentsOf: chromiumProfiles(source: source, root: root))
        }
        let safari = home.appendingPathComponent("Library/Safari")
        let safariBookmarks = safari.appendingPathComponent("Bookmarks.plist")
        let safariHistory = safari.appendingPathComponent("History.db")
        if FileManager.default.fileExists(atPath: safariBookmarks.path) {
            out.append(BrowserImportProfile(
                source: .safari, name: "Safari", profilePath: safari.path,
                bookmarksPath: safariBookmarks.path,
                historyPath: FileManager.default.fileExists(atPath: safariHistory.path)
                    ? safariHistory.path : nil,
                preferencesPath: nil))
        }
        return out
    }

    /// 用户手动选中的文件夹/文件 → 一个可预览的档案（推断来源）。
    static func profile(atPath path: String) -> BrowserImportProfile? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { url = url.deletingLastPathComponent() }
        let lower = url.path.lowercased()
        let source: BrowserImportSource
        if lower.contains("/safari") { source = .safari }
        else if lower.contains("microsoft edge") { source = .edge }
        else if lower.contains("brave") { source = .brave }
        else if lower.contains("/arc/") { source = .arc }
        else { source = .chrome }

        if source == .safari {
            let bookmarks = url.appendingPathComponent("Bookmarks.plist")
            let history = url.appendingPathComponent("History.db")
            guard fm.fileExists(atPath: bookmarks.path) || fm.fileExists(atPath: history.path) else {
                return nil
            }
            return BrowserImportProfile(
                source: .safari, name: "Safari", profilePath: url.path,
                bookmarksPath: fm.fileExists(atPath: bookmarks.path) ? bookmarks.path : nil,
                historyPath: fm.fileExists(atPath: history.path) ? history.path : nil,
                preferencesPath: nil)
        }

        let bookmarks = url.appendingPathComponent("Bookmarks")
        let history = url.appendingPathComponent("History")
        let prefs = url.appendingPathComponent("Preferences")
        guard fm.fileExists(atPath: bookmarks.path)
            || fm.fileExists(atPath: history.path) else { return nil }
        return BrowserImportProfile(
            source: source, name: url.lastPathComponent, profilePath: url.path,
            bookmarksPath: fm.fileExists(atPath: bookmarks.path) ? bookmarks.path : nil,
            historyPath: fm.fileExists(atPath: history.path) ? history.path : nil,
            preferencesPath: fm.fileExists(atPath: prefs.path) ? prefs.path : nil)
    }

    private static func chromiumProfiles(source: BrowserImportSource, root: URL) -> [BrowserImportProfile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let names = profileNames(root: root)
        var out: [BrowserImportProfile] = []
        for dir in entries {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let name = dir.lastPathComponent
            guard name == "Default" || name.hasPrefix("Profile ") else { continue }
            let bookmarks = dir.appendingPathComponent("Bookmarks")
            let history = dir.appendingPathComponent("History")
            let prefs = dir.appendingPathComponent("Preferences")
            guard fm.fileExists(atPath: bookmarks.path) || fm.fileExists(atPath: history.path) else { continue }
            out.append(BrowserImportProfile(
                source: source,
                name: names[name] ?? name,
                profilePath: dir.path,
                bookmarksPath: fm.fileExists(atPath: bookmarks.path) ? bookmarks.path : nil,
                historyPath: fm.fileExists(atPath: history.path) ? history.path : nil,
                preferencesPath: fm.fileExists(atPath: prefs.path) ? prefs.path : nil))
        }
        return out.sorted { $0.profilePath < $1.profilePath }
    }

    /// Chromium `Local State` 的 profile.info_cache 显示名。
    private static func profileNames(root: URL) -> [String: String] {
        let localState = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let rootObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = rootObj["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (key, value) in cache {
            if let dict = value as? [String: Any],
               let name = dict["name"] as? String, !name.isEmpty {
                names[key] = name
            }
        }
        return names
    }

    // MARK: - 预览

    static func preview(_ profile: BrowserImportProfile) -> BrowserImportPreview {
        var result = BrowserImportPreview()
        let fm = FileManager.default

        if let path = profile.bookmarksPath {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                result.bookmarks = profile.source == .safari
                    ? try SafariBookmarksParser.parse(plist: data)
                    : try ChromiumBookmarksParser.parse(data: data)
            } catch {
                result.warnings.append(error.localizedDescription)
            }
        } else {
            result.warnings.append("No bookmarks file found.")
        }

        if let path = profile.historyPath {
            do {
                let sql = profile.source == .safari
                    ? """
                      SELECT i.url AS url, i.title AS title, i.visit_count AS visit_count,
                             MAX(v.visit_time) AS visit_time
                      FROM history_items i
                      LEFT JOIN history_visits v ON v.history_item = i.id
                      GROUP BY i.id
                      ORDER BY visit_time DESC
                      LIMIT 5000;
                      """
                    : """
                      SELECT url, title, visit_count, last_visit_time
                      FROM urls
                      WHERE url IS NOT NULL
                        AND (url LIKE 'http://%' OR url LIKE 'https://%')
                      ORDER BY last_visit_time DESC
                      LIMIT 5000;
                      """
                let data = try sqliteJSON(database: path, sql: sql)
                result.history = profile.source == .safari
                    ? try BrowserHistoryParser.safari(data: data)
                    : try BrowserHistoryParser.chromium(data: data)
            } catch {
                result.warnings.append(error.localizedDescription)
            }
        } else {
            result.warnings.append("No history database found.")
        }

        if let path = profile.preferencesPath {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                result.settings = try chromiumPreferences(data: data)
            } catch {
                result.warnings.append(error.localizedDescription)
            }
        }

        if profile.source == .safari {
            result.warnings.append(
                "Safari passwords aren't imported — export them as CSV from Safari and use Passwords ▸ Import CSV.")
        } else if profile.source.isChromium {
            result.warnings.append(
                "\(profile.source.displayName) passwords are encrypted by the browser — export them as CSV and use Passwords ▸ Import CSV.")
        }
        if !fm.fileExists(atPath: profile.profilePath) {
            result.warnings.append("Profile folder no longer exists.")
        }
        return result
    }

    // MARK: - 落地

    @MainActor
    static func perform(_ profile: BrowserImportProfile,
                        preview: BrowserImportPreview,
                        includeBookmarks: Bool,
                        includeHistory: Bool,
                        includeSettings: Bool,
                        settings: Settings,
                        bookmarkStore: BookmarkStore,
                        historyStore: HistoryStore) -> BrowserImportReport {
        var report = BrowserImportReport()
        report.warnings = preview.warnings

        if includeBookmarks, !preview.bookmarks.isEmpty {
            let outcome = bookmarkStore.mergeImportedTree(
                preview.bookmarks,
                rootTitle: "Imported from \(profile.source.displayName)")
            report.bookmarksImported = outcome.imported
            report.bookmarksSkipped = outcome.skipped
        }

        if includeHistory, !preview.history.isEmpty {
            let outcome = historyStore.mergeImported(preview.history)
            report.historyImported = outcome.added
            report.historySkipped = outcome.skipped
        }

        if includeSettings {
            if let home = preview.settings.homePage,
               let scheme = URLComponents(string: home)?.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                settings.homePage = home
                report.settingsApplied.append("Homepage")
            }
            let urls = StartupPageSet.urls(from: preview.settings.startupURLs.joined(separator: "\n"))
            if !urls.isEmpty {
                settings.startupPageSet = urls.joined(separator: "\n")
                settings.startupBehavior = .pageSet
                report.settingsApplied.append("Startup pages")
            }
        }
        return report
    }

    // MARK: - Chromium Preferences

    private static func chromiumPreferences(data: Data) throws -> BrowserImportSettings {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserImportError.malformed("Preferences is not valid JSON")
        }
        var out = BrowserImportSettings()
        if let home = root["homepage"] as? String,
           !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.homePage = home
        }
        if let session = root["session"] as? [String: Any],
           let urls = session["startup_urls"] as? [String] {
            out.startupURLs = urls
        }
        return out
    }

    // MARK: - SQLite

    /// 复制数据库（含 WAL/SHM）后交给 `/usr/bin/sqlite3 -json` 查询。
    /// 子进程不继承 App 的 TCC 授权，所以必须先复制到 App 可读的临时目录。
    private static func sqliteJSON(database: String, sql: String) throws -> Data {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "desire-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let source = URL(fileURLWithPath: database)
        let copy = tmp.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: database + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: tmp.appendingPathComponent(
                    source.lastPathComponent + suffix))
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", copy.path, sql]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "sqlite3 failed"
            throw BrowserImportError.unreadable(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.fileHandleForReading.readDataToEndOfFile()
    }
}
