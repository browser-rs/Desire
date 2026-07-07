import AppKit
import Combine
import SwiftUI

struct DownloadItem: Identifiable {
    let id: UUID
    var filename: String
    var fileURL: URL?
    var totalBytes: Int64
    var downloadedBytes: Int64
    var state: State
    var error: String?
    var cancel: (() -> Void)?
    var sourceURL: URL?

    enum State: String, Codable { case inProgress, completed, failed }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }

    var isIndeterminate: Bool { totalBytes <= 0 && state == .inProgress }
}

@MainActor
class DownloadStore: ObservableObject {
    @Published var downloads: [DownloadItem] = []
    @Published private(set) var downloadFolder: URL

    private var accessedURL: URL?
    private let bookmarkKey = "desire.downloadFolder.bookmark"
    private let historyKey = "desire.downloadHistory"

    var hasActive: Bool { downloads.contains { $0.state == .inProgress } }
    var activeCount: Int { downloads.filter { $0.state == .inProgress }.count }

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
        downloads[i].totalBytes = totalBytes
        downloads[i].downloadedBytes = downloadedBytes
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
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        downloads = items.map { $0.toDownloadItem() }
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
        let downloadTask = URLSession.shared.downloadTask(with: sourceURL) { [weak self] tempURL, response, error in
            Task { @MainActor in
                guard let self, let tempURL, let response else {
                    if let error {
                        Task { @MainActor in
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

    init(_ item: DownloadItem) {
        id = item.id
        filename = item.filename
        fileURL = item.fileURL
        totalBytes = item.totalBytes
        downloadedBytes = item.downloadedBytes
        state = item.state.rawValue
        error = item.error
        sourceURL = item.sourceURL
    }

    func toDownloadItem() -> DownloadItem {
        DownloadItem(
            id: id, filename: filename, fileURL: fileURL,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes,
            state: DownloadItem.State(rawValue: state) ?? .failed,
            error: error, cancel: nil, sourceURL: sourceURL
        )
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
