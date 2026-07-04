import AppKit
import Combine
import SwiftUI

struct DownloadItem: Identifiable {
    let id = UUID()
    var filename: String
    var fileURL: URL?
    var totalBytes: Int64
    var downloadedBytes: Int64
    var state: State
    var error: String?
    var cancel: (() -> Void)?

    enum State { case inProgress, completed, failed }

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

    private var pollTimer: Timer?
    private var accessedURL: URL?
    private let bookmarkKey = "desire.downloadFolder.bookmark"

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
        ensurePolling()
        return id
    }

    func setDestination(id: UUID, filename: String, fileURL: URL, totalBytes: Int64) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].filename = filename
        downloads[i].fileURL = fileURL
        downloads[i].totalBytes = totalBytes
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
        stopPollingIfNeeded()
    }

    func fail(id: UUID, message: String) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].state = .failed
        downloads[i].error = message
        stopPollingIfNeeded()
    }

    func remove(id: UUID) {
        if let item = downloads.first(where: { $0.id == id }), item.state == .inProgress {
            item.cancel?()
        }
        downloads.removeAll { $0.id == id }
        stopPollingIfNeeded()
    }

    func clearFinished() {
        downloads.removeAll { $0.state != .inProgress }
    }

    func revealInFinder(_ item: DownloadItem) {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFile(_ item: DownloadItem) {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func ensurePolling() {
        guard pollTimer == nil, hasActive else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProgress() }
        }
    }

    private func stopPollingIfNeeded() {
        guard !hasActive else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshProgress() {
        guard hasActive else { stopPollingIfNeeded(); return }
        for i in downloads.indices where downloads[i].state == .inProgress {
            guard let path = downloads[i].fileURL else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size]) as? Int64
            downloads[i].downloadedBytes = size ?? downloads[i].downloadedBytes
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
