import AppKit
import Combine
import SwiftUI

@MainActor
class DownloadStore: ObservableObject {
    @Published var downloads: [DownloadItem] = []
    @Published private(set) var downloadFolder: URL
    @Published var groupingMode: GroupingMode = .date
    @Published var fileTypeFilter: DownloadItem.FileType? = nil

    private var accessedURL: URL?
    private let bookmarkKey = "desire.downloadFolder.bookmark"
    private let historyKey = "desire.downloadHistory"

    enum GroupingMode: String, CaseIterable {
        case date, fileType, status
    }

    var hasActive: Bool { downloads.contains { $0.state == .inProgress && !$0.isPaused } }
    var activeCount: Int { downloads.filter { $0.state == .inProgress && !$0.isPaused }.count }
    var pausedCount: Int { downloads.filter { $0.isPaused }.count }

    init() {
        downloadFolder = DownloadStore.defaultDownloadsURL()
        if let custom = DownloadStore.resolveBookmarkedFolder(bookmarkKey: bookmarkKey) {
            downloadFolder = custom.url
            if custom.url.startAccessingSecurityScopedResource() {
                accessedURL = custom.url
            }
        }
        loadHistory()
    }

    private static func defaultDownloadsURL() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    private static func resolveBookmarkedFolder(bookmarkKey: String) -> (url: URL, data: Data)? {
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

    @discardableResult
    func chooseDownloadFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloadFolder
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        if url.startAccessingSecurityScopedResource() {
            if let data = try? url.bookmarkData(options: [.withSecurityScope]) {
                UserDefaults.standard.set(data, forKey: bookmarkKey)
            }
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = url
        }
        downloadFolder = url
        return true
    }

    func resetToDefaultFolder() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        downloadFolder = DownloadStore.defaultDownloadsURL()
    }

    func uniqueURL(for filename: String) -> URL {
        let base = downloadFolder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = downloadFolder.appendingPathComponent(candidateName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
            i += 1
        }
    }

    @discardableResult
    func add(item: DownloadItem) -> UUID {
        let id = item.id
        downloads.insert(item, at: 0)
        return id
    }

    func setDestination(id: UUID, filename: String, fileURL: URL, totalBytes: Int64) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].filename = filename
        downloads[i].fileURL = fileURL
        downloads[i].totalBytes = totalBytes
    }

    func updateProgress(id: UUID, totalBytes: Int64, downloadedBytes: Int64) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(downloads[i].lastUpdateTime)
        let oldBytes = downloads[i].downloadedBytes
        let newSpeed = elapsed > 0 ? Int64(Double(downloadedBytes - oldBytes) / elapsed) : downloads[i].speed

        downloads[i].totalBytes = totalBytes
        downloads[i].downloadedBytes = downloadedBytes
        downloads[i].speed = max(0, newSpeed)
        downloads[i].lastUpdateTime = now
    }

    func pause(id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }), downloads[i].state == .inProgress else { return }
        downloads[i].isPaused = true
        downloads[i].speed = 0
    }

    func resume(id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }), downloads[i].isPaused else { return }
        downloads[i].isPaused = false
        downloads[i].lastUpdateTime = Date()
    }

    func setPriority(id: UUID, priority: DownloadItem.Priority) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].priority = priority
        // Re-sort downloads by priority
        sortDownloadsByPriority()
    }

    private func sortDownloadsByPriority() {
        downloads.sort { $0.priority.rawValue > $1.priority.rawValue }
    }

    func pauseAll() {
        for i in downloads.indices {
            if downloads[i].state == .inProgress && !downloads[i].isPaused {
                downloads[i].isPaused = true
                downloads[i].speed = 0
            }
        }
    }

    func resumeAll() {
        for i in downloads.indices {
            if downloads[i].isPaused {
                downloads[i].isPaused = false
                downloads[i].lastUpdateTime = Date()
            }
        }
    }

    func cancelAll() {
        for item in downloads where item.state == .inProgress {
            item.cancel?()
        }
        downloads.removeAll { $0.state == .inProgress }
        saveHistory()
    }

    // MARK: - Grouping

    func groupedByDate() -> [(String, [DownloadItem])] {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        guard let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart) else { return [] }
        guard let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else { return [] }
        guard let monthStart = cal.date(byAdding: .month, value: -1, to: now) else { return [] }

        var today: [DownloadItem] = []
        var yesterday: [DownloadItem] = []
        var thisWeek: [DownloadItem] = []
        var thisMonth: [DownloadItem] = []
        var earlier: [DownloadItem] = []

        let filtered = fileTypeFilter != nil
            ? downloads.filter { $0.fileType == fileTypeFilter }
            : downloads

        for item in filtered {
            if item.startTime >= todayStart {
                today.append(item)
            } else if item.startTime >= yesterdayStart {
                yesterday.append(item)
            } else if item.startTime >= weekStart {
                thisWeek.append(item)
            } else if item.startTime >= monthStart {
                thisMonth.append(item)
            } else {
                earlier.append(item)
            }
        }

        var sections: [(String, [DownloadItem])] = []
        if !today.isEmpty { sections.append((String(localized: "Today"), today)) }
        if !yesterday.isEmpty { sections.append((String(localized: "Yesterday"), yesterday)) }
        if !thisWeek.isEmpty { sections.append((String(localized: "This Week"), thisWeek)) }
        if !thisMonth.isEmpty { sections.append((String(localized: "This Month"), thisMonth)) }
        if !earlier.isEmpty { sections.append((String(localized: "Earlier"), earlier)) }
        return sections
    }

    func groupedByFileType() -> [(String, [DownloadItem])] {
        var groups: [DownloadItem.FileType: [DownloadItem]] = [:]
        for item in downloads {
            groups[item.fileType, default: []].append(item)
        }
        return groups.sorted { $0.key.rawValue < $1.key.rawValue }.map { ($0.key.rawValue.capitalized, $0.value) }
    }

    func groupedByStatus() -> [(String, [DownloadItem])] {
        var inProgress: [DownloadItem] = []
        var paused: [DownloadItem] = []
        var completed: [DownloadItem] = []
        var failed: [DownloadItem] = []

        let filtered = fileTypeFilter != nil
            ? downloads.filter { $0.fileType == fileTypeFilter }
            : downloads

        for item in filtered {
            if item.isPaused {
                paused.append(item)
            } else {
                switch item.state {
                case .inProgress: inProgress.append(item)
                case .completed: completed.append(item)
                case .failed: failed.append(item)
                case .paused: paused.append(item)
                }
            }
        }

        var sections: [(String, [DownloadItem])] = []
        if !inProgress.isEmpty { sections.append((String(localized: "In Progress"), inProgress)) }
        if !paused.isEmpty { sections.append((String(localized: "Paused"), paused)) }
        if !completed.isEmpty { sections.append((String(localized: "Completed"), completed)) }
        if !failed.isEmpty { sections.append((String(localized: "Failed"), failed)) }
        return sections
    }

    func complete(id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].state = .completed
        if let url = downloads[i].fileURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 {
            downloads[i].totalBytes = size
            downloads[i].downloadedBytes = size
        } else {
            downloads[i].downloadedBytes = max(downloads[i].totalBytes, 0)
        }
        saveHistory()
        notifyDownload(filename: downloads[i].filename)
    }

    func fail(id: UUID, message: String) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].state = .failed
        downloads[i].error = message
        saveHistory()
    }

    func remove(id: UUID) {
        if let item = downloads.first(where: { $0.id == id }), item.state == .inProgress {
            item.cancel?()
        }
        downloads.removeAll { $0.id == id }
        saveHistory()
    }

    func clearFinished() {
        downloads.removeAll { $0.state != .inProgress }
        saveHistory()
    }

    private func saveHistory() {
        let finished = downloads.filter { $0.state != .inProgress }
        let items = finished.map { HistoryItem($0) }
        DiskStore.save(items, key: historyKey)
    }

    private func loadHistory() {
        if let items = DiskStore.load([HistoryItem].self, key: historyKey) {
            downloads = items.map { $0.toDownloadItem() }
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            downloads = items.map { $0.toDownloadItem() }
            // Re-save finished items to DiskStore and drop the legacy key.
            let finished = downloads.filter { $0.state != .inProgress }.map { HistoryItem($0) }
            DiskStore.save(finished, key: historyKey)
            UserDefaults.standard.removeObject(forKey: historyKey)
        }
    }

    func revealInFinder(_ item: DownloadItem) {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFile(_ item: DownloadItem) {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.open(url)
    }

    func retry(_ item: DownloadItem) {
        guard let sourceURL = item.sourceURL else { return }
        remove(id: item.id)
        let downloadTask = URLSession.shared.downloadTask(with: sourceURL) { tempURL, _, error in
            Task { @MainActor [weak self] in
                guard let self, let tempURL else {
                    if let error {
                        Task { @MainActor [weak self] in
                            _ = self?.add(item: DownloadItem(
                                id: UUID(), filename: item.filename, fileURL: nil,
                                totalBytes: 0, downloadedBytes: 0,
                                state: .failed, error: error.localizedDescription,
                                cancel: nil, sourceURL: sourceURL
                            ))
                        }
                    }
                    return
                }
                let destination = self.uniqueURL(for: item.filename)
                try? FileManager.default.moveItem(at: tempURL, to: destination)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
                _ = self.add(item: DownloadItem(
                    id: UUID(), filename: item.filename, fileURL: destination,
                    totalBytes: size, downloadedBytes: size,
                    state: .completed, error: nil,
                    cancel: nil, sourceURL: sourceURL
                ))
                self.notifyDownload(filename: item.filename)
            }
        }
        downloadTask.resume()
        _ = add(item: DownloadItem(
            id: UUID(), filename: item.filename, fileURL: nil,
            totalBytes: 0, downloadedBytes: 0,
            state: .inProgress, error: nil,
            cancel: { downloadTask.cancel() }, sourceURL: sourceURL
        ))
    }

    private func notifyDownload(filename: String) {
        NSApp.requestUserAttention(.informationalRequest)
        let userInfo: [String: Any] = ["filename": filename]
        let notification = NSUserNotification()
        notification.title = "下载完成"
        notification.informativeText = filename
        notification.userInfo = userInfo
        NSUserNotificationCenter.default.deliver(notification)
    }
}

private struct HistoryItem: Codable {
    let id: UUID
    var filename: String
    var fileURL: URL?
    var totalBytes: Int64
    var downloadedBytes: Int64
    var state: String
    var error: String?
    var sourceURL: URL?
    var priority: Int
    var startTime: Date

    init(_ item: DownloadItem) {
        id = item.id
        filename = item.filename
        fileURL = item.fileURL
        totalBytes = item.totalBytes
        downloadedBytes = item.downloadedBytes
        state = item.state.rawValue
        error = item.error
        sourceURL = item.sourceURL
        priority = item.priority.rawValue
        startTime = item.startTime
    }

    func toDownloadItem() -> DownloadItem {
        DownloadItem(
            id: id, filename: filename, fileURL: fileURL,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes,
            state: DownloadItem.State(rawValue: state) ?? .failed,
            error: error, cancel: nil, sourceURL: sourceURL,
            priority: DownloadItem.Priority(rawValue: priority) ?? .normal,
            startTime: startTime
        )
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func formatSpeed(_ bytesPerSecond: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytesPerSecond) + "/s"
}

func formatTimeRemaining(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "" }
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    let secs = Int(seconds) % 60

    if hours > 0 {
        return String(localized: "\(hours)h \(minutes)m")
    } else if minutes > 0 {
        return String(localized: "\(minutes)m \(secs)s")
    } else {
        return String(localized: "\(secs)s")
    }
}
