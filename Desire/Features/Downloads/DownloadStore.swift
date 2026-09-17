import AppKit
import Combine
import SwiftUI
// `@preconcurrency`: UNUserNotificationCenter is thread-safe but predates
// Sendable annotations, which trips strict-concurrency captures.
@preconcurrency import UserNotifications

@MainActor
class DownloadStore: ObservableObject {
    /// The app's primary store instance — the automation bridge reads this
    /// (multiple instances may exist; in-flight state lives only here).
    static private(set) weak var live: DownloadStore?

    @Published var downloads: [DownloadItem] = []
    @Published private(set) var downloadFolder: URL
    @Published var groupingMode: GroupingMode = .date
    @Published var fileTypeFilter: DownloadItem.FileType? = nil

    private var accessedURL: URL?
    private let bookmarkKey = "desire.downloadFolder.bookmark"
    private let historyKey = "desire.downloadHistory"
    /// Active URLSession download tasks keyed by DownloadItem.id, so
    /// pause/resume can actually suspend/resume the network transfer.
    private var activeTasks: [UUID: URLSessionDownloadTask] = [:]

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
        DownloadStore.live = self
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
        guard !downloads[i].isPaused else { return }
        downloads[i].isPaused = true
        downloads[i].speed = 0
        // Real transfer pause: URLSession tasks suspend; webview downloads
        // cancel-with-resume-data (WKDownload cannot be suspended).
        if let pauseAction = downloads[i].pauseAction {
            pauseAction()
        } else {
            activeTasks[id]?.suspend()
        }
    }

    func resume(id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }), downloads[i].isPaused else { return }
        downloads[i].isPaused = false
        downloads[i].lastUpdateTime = Date()
        if let resumeAction = downloads[i].resumeAction {
            resumeAction(downloads[i].resumeData)
        } else {
            activeTasks[id]?.resume()
        }
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
        for i in downloads.indices where downloads[i].state == .inProgress && !downloads[i].isPaused {
            pause(id: downloads[i].id)
        }
    }

    func resumeAll() {
        for i in downloads.indices where downloads[i].isPaused {
            resume(id: downloads[i].id)
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
        // Paused downloads must survive quit too — the partial file is on
        // disk and the user expects the row back on relaunch.
        let finished = downloads.filter { $0.state != .inProgress || $0.isPaused }
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

    /// Re-runs a failed download. Prefers the item's stored resume data
    /// (partial transfer continues); falls back to a fresh request.
    func retry(_ item: DownloadItem) {
        if item.resumeData != nil, let resumeAction = item.resumeAction {
            guard let i = downloads.firstIndex(where: { $0.id == item.id }) else { return }
            downloads[i].state = .inProgress
            downloads[i].isPaused = false
            downloads[i].error = nil
            downloads[i].lastUpdateTime = Date()
            resumeAction(item.resumeData)
            return
        }
        guard let sourceURL = item.sourceURL else { return }
        remove(id: item.id)
        startURLSessionDownload(sourceURL: sourceURL, filename: item.filename)
    }

    /// Store-owned transfer for retries ("下载链接" style): validates the HTTP
    /// status (URLSession hands us the ERROR PAGE for a 404 and would happily
    /// save it as the file), classifies failures, and captures resume data
    /// when the server allows ranges.
    private func startURLSessionDownload(sourceURL: URL, filename: String, resumeData: Data? = nil) {
        let itemId = UUID()
        let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                self?.finishURLSessionDownload(id: itemId, tempURL: tempURL, response: response, error: error)
            }
        }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = URLSession.shared.downloadTask(withResumeData: resumeData, completionHandler: completion)
        } else {
            task = URLSession.shared.downloadTask(with: sourceURL, completionHandler: completion)
        }
        activeTasks[itemId] = task
        var item = DownloadItem(
            id: itemId, filename: filename, fileURL: nil,
            totalBytes: 0, downloadedBytes: 0,
            state: .inProgress, error: nil,
            cancel: { [weak task] in
                task?.cancel(byProducingResumeData: { _ in })
            },
            sourceURL: sourceURL
        )
        item.pauseAction = { [weak task] in task?.suspend() }
        item.resumeAction = { [weak task] (_: Data?) in task?.resume() }
        _ = add(item: item)
        task.resume()
    }

    private func finishURLSessionDownload(id: UUID, tempURL: URL?, response: URLResponse?, error: Error?) {
        activeTasks[id] = nil
        if let error {
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            storeResumeData(resumeData, for: id)
            fail(id: id, message: DownloadFailure.describe(error))
            return
        }
        // A 4xx/5xx response still "succeeds" as a transfer — the payload is
        // the server's error page. Never write that as the downloaded file.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            fail(id: id, message: DownloadFailure.httpStatus(http.statusCode))
            return
        }
        guard let tempURL else {
            fail(id: id, message: String(localized: "The download produced no file"))
            return
        }
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        let destination = uniqueURL(for: downloads[i].filename)
        try? FileManager.default.moveItem(at: tempURL, to: destination)
        downloads[i].fileURL = destination
        complete(id: id)
    }

    /// Stashes resume data on the item (in-memory) so pause/retry can
    /// continue the partial transfer.
    func storeResumeData(_ data: Data?, for id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].resumeData = data
    }

    /// Maps transfer failures to short, actionable localized messages.
    enum DownloadFailure {
        static func describe(_ error: Error) -> String {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet: return String(localized: "No internet connection")
                case .networkConnectionLost: return String(localized: "Connection lost")
                case .timedOut: return String(localized: "Connection timed out")
                case .cannotFindHost, .dnsLookupFailed: return String(localized: "Server not found")
                case .cannotConnectToHost: return String(localized: "Could not connect to the server")
                case .secureConnectionFailed, .serverCertificateUntrusted:
                    return String(localized: "Secure connection failed")
                default: break
                }
            }
            return error.localizedDescription
        }

        static func httpStatus(_ code: Int) -> String {
            switch code {
            case 401, 403: return String(localized: "Server requires authentication")
            case 404: return String(localized: "File not found on the server (404)")
            case 408: return String(localized: "Request timed out")
            case 500...599: return String(localized: "Server error (\(code))")
            default: return String(localized: "Server returned HTTP \(code)")
            }
        }
    }

    private func notifyDownload(filename: String) {
        NSApp.requestUserAttention(.informationalRequest)
        // NSUserNotification was deprecated in macOS 11; UserNotifications is
        // the replacement. The authorization prompt is shown once — macOS
        // remembers the decision, so a repeated request is a no-op.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "下载完成"
            content.body = filename
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
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
