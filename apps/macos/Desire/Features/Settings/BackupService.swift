import Foundation

/// 统一备份/恢复（v0.7.28 旗舰）：把设置、书签树、历史、阅读列表、快拨与
/// Agent 记忆打包成一个**版本化 JSON**；导入支持 Merge（只补缺）与 Replace
/// （整体还原，调用方负责二次确认）。
///
/// 边界：**不碰 Keychain / API Key / 同步主密钥 / 对话正文**——备份文件可安全
/// 放在本地目录，仍建议用户自行保管（历史与记忆属于隐私）。
@MainActor
enum BackupService {
    enum Mode: String {
        case merge
        case replace
    }

    enum BackupError: LocalizedError {
        case appNotReady
        case invalidArchive
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .appNotReady: return String(localized: "The browser is not ready yet.")
            case .invalidArchive: return String(localized: "This file is not a Desire backup.")
            case .unsupportedVersion(let v):
                return String(format: String(localized: "Backup format %lld is newer than this app supports."), v)
            }
        }
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "desire-backup-\(formatter.string(from: now)).json"
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("DesireAgent/backups", isDirectory: true)
    }

    // MARK: - Export

    /// 写到调用方指定的**文件 URL**（UI 用保存面板，桥直接给路径）。
    @discardableResult
    static func export(to url: URL) throws -> (url: URL, counts: [String: Int]) {
        guard let app = AppState.live else { throw BackupError.appNotReady }

        var payloads: [String: Data] = [:]
        var counts: [String: Int] = [:]

        if let data = BackupArchive.encodePayload(app.bookmarkStore.bookmarks) {
            payloads[BackupArchive.Domain.bookmarks.rawValue] = data
            counts[BackupArchive.Domain.bookmarks.rawValue] = totalBookmarks(app.bookmarkStore.bookmarks)
        }
        if let data = BackupArchive.encodePayload(app.historyStore.entries) {
            payloads[BackupArchive.Domain.history.rawValue] = data
            counts[BackupArchive.Domain.history.rawValue] = app.historyStore.entries.count
        }
        if let data = BackupArchive.encodePayload(app.readingListStore.items) {
            payloads[BackupArchive.Domain.readingList.rawValue] = data
            counts[BackupArchive.Domain.readingList.rawValue] = app.readingListStore.items.count
        }
        if let data = BackupArchive.encodePayload(app.quickDialStore.dials) {
            payloads[BackupArchive.Domain.quickDials.rawValue] = data
            counts[BackupArchive.Domain.quickDials.rawValue] = app.quickDialStore.dials.count
        }

        var settings: [String: BackupSettingValue] = [:]
        for entry in SettingsSync.catalog {
            guard let value = entry.read(app.settings) else { continue }
            settings[entry.key] = backupValue(value)
        }
        if let data = BackupArchive.encodePayload(settings) {
            payloads[BackupArchive.Domain.settings.rawValue] = data
            counts[BackupArchive.Domain.settings.rawValue] = settings.count
        }

        let memory = AgentMemoryStore.shared.archive
        if let data = BackupArchive.encodePayload(memory) {
            payloads[BackupArchive.Domain.agentMemory.rawValue] = data
            counts[BackupArchive.Domain.agentMemory.rawValue] = memory.facts.count + memory.summaries.count
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let archive = BackupArchive(version: BackupArchive.currentVersion,
                                    exportedAt: Date(),
                                    appVersion: version,
                                    payloads: payloads,
                                    counts: counts)
        guard let data = BackupArchive.encode(archive) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return (url, counts)
    }

    /// 桥的便捷形式：给目录就自动取默认文件名。
    @discardableResult
    static func export(toDirectory directory: URL) throws -> (url: URL, counts: [String: Int]) {
        try export(to: directory.appendingPathComponent(suggestedFileName()))
    }

    // MARK: - Import

    /// 导入前预览（v0.7.28）：只读文件头，不碰任何 store。
    struct Preview {
        var version: Int
        var exportedAt: Date
        var appVersion: String
        var counts: [String: Int]
        var supported: Bool
    }

    static func preview(from url: URL) throws -> Preview {
        let data = try Data(contentsOf: url)
        guard let archive = BackupArchive.decode(data), !archive.payloads.isEmpty else {
            throw BackupError.invalidArchive
        }
        return Preview(version: archive.version,
                       exportedAt: archive.exportedAt,
                       appVersion: archive.appVersion,
                       counts: archive.counts,
                       supported: archive.isSupported)
    }

    @discardableResult
    static func importArchive(from url: URL, mode: Mode,
                              domains: Set<BackupArchive.Domain>? = nil) throws -> [String: Int] {
        guard let app = AppState.live else { throw BackupError.appNotReady }
        let data = try Data(contentsOf: url)
        guard let archive = BackupArchive.decode(data), !archive.payloads.isEmpty else {
            throw BackupError.invalidArchive
        }
        guard archive.isSupported else {
            throw BackupError.unsupportedVersion(archive.version)
        }
        let wanted: (BackupArchive.Domain) -> Bool = { domains?.contains($0) ?? true }

        var applied: [String: Int] = [:]
        let decoder = JSONDecoder()

        if wanted(.bookmarks), let payload = archive.payloads[BackupArchive.Domain.bookmarks.rawValue],
           let tree = try? decoder.decode([Bookmark].self, from: payload) {
            switch mode {
            case .replace:
                app.bookmarkStore.replaceForSync(tree)
                applied[BackupArchive.Domain.bookmarks.rawValue] = totalBookmarks(tree)
            case .merge:
                let title = String(format: String(localized: "Imported %@"),
                                   DateFormatter.localizedString(from: Date(),
                                                                 dateStyle: .short,
                                                                 timeStyle: .none))
                applied[BackupArchive.Domain.bookmarks.rawValue] =
                    app.bookmarkStore.mergeImported(tree, folderTitle: title)
            }
        }

        if wanted(.history), let payload = archive.payloads[BackupArchive.Domain.history.rawValue],
           let entries = try? decoder.decode([HistoryEntry].self, from: payload) {
            switch mode {
            case .replace:
                app.historyStore.replaceForSync(entries)
                applied[BackupArchive.Domain.history.rawValue] = entries.count
            case .merge:
                let existing = Set(app.historyStore.entries.map(\.url))
                let missing = entries.filter { !existing.contains($0.url) }
                for entry in missing {
                    app.historyStore.addEntry(url: entry.url, title: entry.title)
                }
                applied[BackupArchive.Domain.history.rawValue] = missing.count
            }
        }

        if wanted(.readingList), let payload = archive.payloads[BackupArchive.Domain.readingList.rawValue],
           let items = try? decoder.decode([ReadingListItem].self, from: payload) {
            switch mode {
            case .replace:
                app.readingListStore.replaceForSync(items)
                applied[BackupArchive.Domain.readingList.rawValue] = items.count
            case .merge:
                let existing = Set(app.readingListStore.items.map(\.url))
                let missing = items.filter { !existing.contains($0.url) }
                for item in missing {
                    app.readingListStore.add(title: item.title, url: item.url)
                }
                applied[BackupArchive.Domain.readingList.rawValue] = missing.count
            }
        }

        if wanted(.quickDials), let payload = archive.payloads[BackupArchive.Domain.quickDials.rawValue],
           let dials = try? decoder.decode([QuickDial].self, from: payload) {
            switch mode {
            case .replace:
                app.quickDialStore.replaceForSync(dials)
                applied[BackupArchive.Domain.quickDials.rawValue] = dials.count
            case .merge:
                let existing = Set(app.quickDialStore.dials.map(\.url))
                let missing = dials.filter { !existing.contains($0.url) }
                for dial in missing {
                    app.quickDialStore.add(title: dial.title, url: dial.url)
                }
                applied[BackupArchive.Domain.quickDials.rawValue] = missing.count
            }
        }

        if wanted(.settings), let payload = archive.payloads[BackupArchive.Domain.settings.rawValue],
           let values = try? decoder.decode([String: BackupSettingValue].self, from: payload) {
            switch mode {
            case .replace:
                var count = 0
                for (key, value) in values {
                    guard let entry = SettingsSync.entry(forKey: key),
                          entry.apply(app.settings, syncValue(value)) else { continue }
                    count += 1
                }
                applied[BackupArchive.Domain.settings.rawValue] = count
            case .merge:
                // 设置没有"缺省"概念（false 也是值）：合并时不动设置，避免
                // 用旧备份覆盖用户当前偏好。UI/文档明确说明。
                applied[BackupArchive.Domain.settings.rawValue] = 0
            }
        }

        if wanted(.agentMemory), let payload = archive.payloads[BackupArchive.Domain.agentMemory.rawValue],
           let memory = try? decoder.decode(MemoryArchive.self, from: payload) {
            let result = AgentMemoryStore.shared.importArchive(
                memory, mode: mode == .replace ? .replace : .merge)
            applied[BackupArchive.Domain.agentMemory.rawValue] = result.facts + result.summaries
        }

        return applied
    }

    // MARK: - Helpers

    private static func backupValue(_ value: SettingsSyncValue) -> BackupSettingValue {
        switch value {
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        }
    }

    private static func syncValue(_ value: BackupSettingValue) -> SettingsSyncValue {
        switch value {
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .number(let n): return .number(n)
        }
    }

    private static func flatBookmarks(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { [$0] + flatBookmarks($0.children) }
    }

    private static func totalBookmarks(_ nodes: [Bookmark]) -> Int {
        flatBookmarks(nodes).count
    }
}
