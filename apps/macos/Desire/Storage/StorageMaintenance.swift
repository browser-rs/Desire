import AppKit
import Foundation
import os

/// **存储健康 + 统一 GC**（v0.8.80 批 6）：按域统计体量、支持显式清理，
/// 并做启动后 + 每日一次的保留策略执行。判定在 `StorageRetention`（harness），
/// IO 在这里；桥 `GET /diag/storage`、设置页"存储"与 Doctor 同源。
@MainActor
enum StorageMaintenance {
    struct DomainInfo {
        let id: String
        let title: String
        let bytes: Int
        let count: Int
        let clearable: Bool
    }

    private static var started = false

    /// 启动后 10s 跑一次，之后每 24h 一次（低频，不占启动路径）。
    static func start() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            runScheduled()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                guard !Task.isCancelled else { return }
                runScheduled()
            }
        }
    }

    // MARK: - 扫描

    static func scan() -> [DomainInfo] {
        let files = diskEntries()
        func group(_ id: String, _ title: String, _ match: (String) -> Bool) -> DomainInfo {
            let hit = files.filter { match($0.path) }
            return DomainInfo(id: id, title: title,
                              bytes: hit.reduce(0) { $0 + $1.bytes },
                              count: hit.count, clearable: true)
        }
        let conversations = group("conversations", String(localized: "Conversations")) {
            let name = ($0 as NSString).lastPathComponent
            return name.hasPrefix("conversation-") && !name.contains(".archive")
        }
        let archives = group("archives", String(localized: "Archived conversations")) {
            ($0 as NSString).lastPathComponent.contains(".archive.json")
        }
        let sessions = group("sessions", String(localized: "Window sessions")) {
            ($0 as NSString).lastPathComponent.hasPrefix("session-")
        }
        let translations = group("translations", String(localized: "Translation caches")) {
            let name = ($0 as NSString).lastPathComponent
            return name == "translation-cache.json"
                || name.hasPrefix("reader.translations.")
                || name.hasPrefix("ebook.translations.")
        }
        let batchLogs = group("batchLogs", String(localized: "Batch download logs")) {
            ($0 as NSString).lastPathComponent.hasPrefix("batch-log-")
        }
        let memory = group("memory", String(localized: "Agent memory")) {
            ($0 as NSString).lastPathComponent.hasPrefix("agent-memory")
        }
        let toolResults = directoryInfo(id: "toolResults", title: String(localized: "Spilled tool results"),
                                        url: StorageRoot.directory
                                            .appendingPathComponent("tool-results", isDirectory: true))
        let resume = directoryInfo(id: "downloadResume", title: String(localized: "Download resume data"),
                                   url: StorageRoot.directory
                                    .appendingPathComponent("download-resume", isDirectory: true))
        let batchArchive = directoryInfo(id: "batchArchive", title: String(localized: "Batch log archive"),
                                         url: StorageRoot.directory
                                            .appendingPathComponent("batch-log-archive", isDirectory: true))
        let knownBytes = [conversations, archives, sessions, translations, batchLogs, memory]
            .reduce(0) { $0 + $1.bytes }
        let totalFiles = files.reduce(0) { $0 + $1.bytes }
        let other = DomainInfo(id: "other", title: String(localized: "Other app data"),
                               bytes: max(0, totalFiles - knownBytes),
                               count: 0, clearable: false)
        return [conversations, archives, sessions, translations, batchLogs, memory,
                toolResults, resume, batchArchive, other]
    }

    static func totalBytes() -> Int {
        scan().reduce(0) { $0 + $1.bytes }
    }

    // MARK: - 清理

    @discardableResult
    static func clean(domain: String, olderThanDays: Int? = nil) -> [String: Any] {
        let fm = FileManager.default
        var removed = 0
        var bytes = 0
        switch domain {
        case "translations":
            for entry in diskEntries() {
                let name = (entry.path as NSString).lastPathComponent
                guard name == "translation-cache.json" || name.hasPrefix("reader.translations.")
                        || name.hasPrefix("ebook.translations.") else { continue }
                if (try? fm.removeItem(atPath: entry.path)) != nil {
                    removed += 1
                    bytes += entry.bytes
                }
            }
            BilingualReadingService.clearCache()
        case "batchLogs":
            for entry in diskEntries() where (entry.path as NSString).lastPathComponent.hasPrefix("batch-log-") {
                if (try? fm.removeItem(atPath: entry.path)) != nil {
                    removed += 1
                    bytes += entry.bytes
                }
            }
        case "toolResults":
            let dir = StorageRoot.directory.appendingPathComponent("tool-results", isDirectory: true)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? fm.removeItem(at: url)) != nil {
                    removed += 1
                    bytes += size
                }
            }
        case "downloadResume":
            let dir = StorageRoot.directory.appendingPathComponent("download-resume", isDirectory: true)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? fm.removeItem(at: url)) != nil {
                    removed += 1
                    bytes += size
                }
            }
        case "batchArchive":
            let dir = StorageRoot.directory.appendingPathComponent("batch-log-archive", isDirectory: true)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? fm.removeItem(at: url)) != nil {
                    removed += 1
                    bytes += size
                }
            }
        case "conversations", "archives":
            let days = olderThanDays ?? retentionDays(for: domain)
            guard days > 0 else {
                return ["ok": false, "error": "set a retention period first (olderThanDays > 0)"]
            }
            let entries = diskEntries().filter { entry in
                let name = (entry.path as NSString).lastPathComponent
                if domain == "conversations" {
                    return name.hasPrefix("conversation-") && !name.contains(".archive")
                }
                return name.contains(".archive.json")
            }
            let liveKey = AgentScheduler.shared.deliveryTarget?.conversationId.map {
                "conversation-\($0.uuidString).json"
            }
            for path in StorageRetention.expired(entries, retentionDays: days) {
                let name = (path as NSString).lastPathComponent
                if let liveKey, name.hasPrefix(liveKey.replacingOccurrences(of: ".json", with: "")) {
                    continue   // 当前打开的会话永不自动删
                }
                if let size = entries.first(where: { $0.path == path })?.bytes,
                   (try? fm.removeItem(atPath: path)) != nil {
                    removed += 1
                    bytes += size
                }
                try? fm.removeItem(atPath: path + ".bak")
            }
        default:
            return ["ok": false, "error": "domain is not clearable"]
        }
        return ["ok": true, "domain": domain, "removed": removed, "bytes": bytes]
    }

    // MARK: - 保留策略

    static func retentionDays(for domain: String) -> Int {
        let key = domain == "archives" ? "storageArchiveRetentionDays" : "storageConversationRetentionDays"
        return max(0, AppPrefs.defaults.integer(forKey: key))
    }

    static func setRetentionDays(_ days: Int, for domain: String) {
        let key = domain == "archives" ? "storageArchiveRetentionDays" : "storageConversationRetentionDays"
        AppPrefs.defaults.set(max(0, days), forKey: key)
    }

    static let translationCacheBudgetBytes = 50_000_000

    /// 启动/每日统一 GC：翻译缓存 50MB LRU + 转存目录 + 批次日志归档 + 可选会话保留。
    static func runScheduled() {
        let fm = FileManager.default
        // 翻译缓存总预算（翻译条/阅读器/电子书三处共用 50MB）。
        let translationFiles = diskEntries().filter {
            let name = ($0.path as NSString).lastPathComponent
            return name == "translation-cache.json" || name.hasPrefix("reader.translations.")
                || name.hasPrefix("ebook.translations.")
        }
        for path in StorageRetention.lruTargets(translationFiles,
                                                maxBytes: translationCacheBudgetBytes) {
            try? fm.removeItem(atPath: path)
        }
        // 转存目录（自带 6h 节流与 1GB/30 天双阈值）。
        ToolResultSpill.runHousekeepingIfNeeded(
            directory: AgentWorkspace.shared.directory
                .appendingPathComponent("tool-results", isDirectory: true))
        // 批次日志归档保留 100 份（按修改时间）。
        let archiveDir = StorageRoot.directory.appendingPathComponent("batch-log-archive", isDirectory: true)
        let archiveFiles = ((try? fm.contentsOfDirectory(
            at: archiveDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
        for stale in archiveFiles.dropLast(100) { try? fm.removeItem(at: stale) }
        // 可选：会话/归档按天保留（默认关闭——用户显式设置才生效）。
        for domain in ["conversations", "archives"] where retentionDays(for: domain) > 0 {
            _ = clean(domain: domain, olderThanDays: retentionDays(for: domain))
        }
        // 历史保留（v0.8.81 批 2）：设置页与每日 GC 共用同一键。
        let historyDays = max(0, AppPrefs.defaults.integer(forKey: "historyRetentionDays"))
        if historyDays > 0, let history = AppState.live?.historyStore {
            history.removeAll(before: Date().addingTimeInterval(-Double(historyDays) * 86_400))
        }
        Log.storage.info("storage GC: total \(totalBytes(), privacy: .public) bytes")
    }

    // MARK: - IO

    private static func diskEntries() -> [StorageRetention.FileEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: DiskStore.directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return [] }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isDirectory != true else { return nil }
            return StorageRetention.FileEntry(path: url.path,
                                              bytes: values?.fileSize ?? 0,
                                              modified: values?.contentModificationDate ?? .distantPast)
        }
    }

    private static func directoryInfo(id: String, title: String, url: URL) -> DomainInfo {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return DomainInfo(id: id, title: title, bytes: 0, count: 0, clearable: true)
        }
        let sizes = urls.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return DomainInfo(id: id, title: title, bytes: sizes.reduce(0, +),
                          count: urls.count, clearable: true)
    }
}
