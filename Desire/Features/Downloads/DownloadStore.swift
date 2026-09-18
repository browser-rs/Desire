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
    /// Store-owned session: the completion-handler download API only
    /// reports at the END of a transfer (restarted downloads sat frozen at
    /// 0 bytes), so progress flows through the delegate instead.
    private lazy var storeSession: URLSession = {
        URLSession(configuration: .default, delegate: StoreDownloadDelegate(store: self), delegateQueue: nil)
    }()
    /// Resume requests parked because the webview's checkpoint data had not
    /// arrived yet: pausing a webview download cancels it and the resume
    /// data is delivered asynchronously — resuming with a nil checkpoint
    /// strands the row (unpaused, nothing transferring).
    private var pendingResumeIDs: Set<UUID> = []

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
        syncDockBadge()
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
        // Persist immediately — a quit/crash right after pausing must not
        // resurrect the row as fake-active on next launch.
        saveHistory()
    }

    func resume(id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }), downloads[i].isPaused else { return }
        // Webview pause is a resume-data checkpoint that lands asynchronously.
        // If it hasn't arrived yet, park the request — storeResumeData fires
        // it the moment the checkpoint is in.
        if downloads[i].resumeAction != nil, downloads[i].resumeData == nil {
            if downloads[i].resumeUnavailable {
                restartFromSource(id: id)
            } else {
                pendingResumeIDs.insert(id)
            }
            return
        }
        // Rows restored from disk have no live transfer behind them —
        // resume means restarting from the source URL.
        if downloads[i].resumeAction == nil, activeTasks[id] == nil {
            restartFromSource(id: id)
            return
        }
        performResume(id: id)
    }

    private func performResume(id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }), downloads[i].isPaused else { return }
        downloads[i].isPaused = false
        downloads[i].lastUpdateTime = Date()
        if let resumeAction = downloads[i].resumeAction {
            resumeAction(downloads[i].resumeData)
        } else {
            activeTasks[id]?.resume()
        }
        saveHistory()
    }

    /// Checkpoint resume is impossible (no usable resume data, e.g. a server
    /// that ignores Range requests): restart the transfer from scratch on the
    /// same row identity the user sees. Falls back to failing the row when
    /// the source URL is unknown.
    private func restartFromSource(id: UUID) {
        pendingResumeIDs.remove(id)
        guard let item = downloads.first(where: { $0.id == id }), let sourceURL = item.sourceURL else {
            fail(id: id, message: String(localized: "This download cannot be resumed"))
            return
        }
        let filename = item.filename
        let wasPrivate = item.isPrivate
        // The partial file cannot be continued — delete it so the fresh
        // transfer reclaims the original destination name instead of leaving
        // an orphan partial and landing on "name 2.zip".
        if let partial = item.fileURL, item.state != .completed,
           FileManager.default.fileExists(atPath: partial.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        remove(id: id)
        startURLSessionDownload(sourceURL: sourceURL, filename: filename, isPrivate: wasPrivate)
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
        syncDockBadge()
        queueCompletionNotification(filename: downloads[i].filename)
    }

    func fail(id: UUID, message: String) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].state = .failed
        downloads[i].error = message
        saveHistory()
    }

    func remove(id: UUID) {
        pendingResumeIDs.remove(id)
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
        // disk and the user expects the row back on relaunch. Incognito
        // downloads are excluded: they must leave no trace on disk.
        let finished = downloads.filter { !$0.isPrivate && ($0.state != .inProgress || $0.isPaused) }
        let items = finished.map { HistoryItem($0) }
        DiskStore.save(items, key: historyKey)
        syncDockBadge()
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
        let wasPrivate = item.isPrivate
        remove(id: item.id)
        startURLSessionDownload(sourceURL: sourceURL, filename: item.filename, isPrivate: wasPrivate)
    }

    /// Store-owned transfer for retries ("下载链接" style): validates the HTTP
    /// status (URLSession hands us the ERROR PAGE for a 404 and would happily
    /// save it as the file), classifies failures, and captures resume data
    /// when the server allows ranges. Progress arrives via StoreDownloadDelegate.
    private func startURLSessionDownload(sourceURL: URL, filename: String, resumeData: Data? = nil, isPrivate: Bool = false) {
        let itemId = UUID()
        let task: URLSessionDownloadTask
        if let resumeData {
            task = storeSession.downloadTask(withResumeData: resumeData)
        } else {
            task = storeSession.downloadTask(with: sourceURL)
        }
        // The delegate routes progress/completion back by id.
        task.taskDescription = itemId.uuidString
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
        item.isPrivate = isPrivate
        item.pauseAction = { [weak task] in task?.suspend() }
        item.resumeAction = { [weak task] (_: Data?) in task?.resume() }
        _ = add(item: item)
        task.resume()
    }

    /// Delegate-only: called by `StoreDownloadDelegate` (same file) with the
    /// moved temp file or a transfer error.
    fileprivate func finishURLSessionDownload(id: UUID, tempURL: URL?, response: URLResponse?, error: Error?) {
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
    /// continue the partial transfer, and fires any resume request that was
    /// parked while the checkpoint was in flight.
    func storeResumeData(_ data: Data?, for id: UUID) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].resumeData = data
        if let data, !data.isEmpty {
            if pendingResumeIDs.remove(id) != nil {
                performResume(id: id)
            }
        } else {
            // WebKit cannot checkpoint this transfer — a parked resume (or a
            // later one) must restart from the source instead.
            downloads[i].resumeUnavailable = true
            if pendingResumeIDs.remove(id) != nil {
                restartFromSource(id: id)
            }
        }
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

    // MARK: - Completion notification throttle & Dock badge

    /// Completions inside this window collapse into ONE notification —
    /// a 10-file batch must not ring the bell ten times.
    private var completedBuffer = 0
    private var notificationTask: Task<Void, Never>?

    private func queueCompletionNotification(filename: String) {
        completedBuffer += 1
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.completedBuffer > 0 else { return }
            let count = self.completedBuffer
            self.completedBuffer = 0
            self.notifyCompleted(count: count, lastFilename: filename)
        }
    }

    private func notifyCompleted(count: Int, lastFilename: String) {
        NSApp.requestUserAttention(.informationalRequest)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            if count == 1 {
                content.title = String(localized: "Download Complete")
                content.body = lastFilename
            } else {
                content.title = String(localized: "Downloads Complete")
                content.body = String(localized: "\(count) files finished downloading")
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    /// Mirror the active-download count on the Dock icon; clear when idle.
    private func syncDockBadge() {
        NSApp.dockTile.badgeLabel = hasActive ? "\(activeCount)" : nil
    }
}

/// Bridges `URLSessionDownloadDelegate` callbacks into the (MainActor)
/// `DownloadStore`. The task's `taskDescription` carries the item id.
private final class StoreDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: DownloadStore?

    init(store: DownloadStore) {
        self.store = store
        super.init()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor [weak store] in
            store?.updateProgress(id: id, totalBytes: totalBytesExpectedToWrite, downloadedBytes: totalBytesWritten)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted as soon as this method returns —
        // move it somewhere stable before hopping to the main actor.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("desire-dl-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: stable)
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let response = downloadTask.response
        Task { @MainActor [weak store] in
            store?.finishURLSessionDownload(id: id, tempURL: stable, response: response, error: nil)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              let downloadTask = task as? URLSessionDownloadTask,
              let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        // Success already went through didFinishDownloadingTo.
        let response = downloadTask.response
        Task { @MainActor [weak store] in
            store?.finishURLSessionDownload(id: id, tempURL: nil, response: response, error: error)
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
    /// Restored rows must come back PAUSED (with no live transfer behind
    /// them); without this they loaded as fake-active zombie rows.
    var isPaused: Bool = false

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
        isPaused = item.isPaused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        state = try container.decode(String.self, forKey: .state)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        priority = try container.decode(Int.self, forKey: .priority)
        startTime = try container.decode(Date.self, forKey: .startTime)
        // Pre-2026-09 blobs have no isPaused key.
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
    }

    func toDownloadItem() -> DownloadItem {
        var item = DownloadItem(
            id: id, filename: filename, fileURL: fileURL,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes,
            state: DownloadItem.State(rawValue: state) ?? .failed,
            error: error, cancel: nil, sourceURL: sourceURL,
            priority: DownloadItem.Priority(rawValue: priority) ?? .normal,
            startTime: startTime
        )
        item.isPaused = isPaused && state == DownloadItem.State.inProgress.rawValue
        return item
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    // .useBytes matters: without it a 32-byte file rounds to "0 KB".
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
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
