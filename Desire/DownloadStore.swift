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

    func add(item: DownloadItem) {
        downloads.insert(item, at: 0)
        ensurePolling()
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
        downloads[i].downloadedBytes = downloads[i].totalBytes
        stopPollingIfNeeded()
    }

    func fail(id: UUID, message: String) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[i].state = .failed
        downloads[i].error = message
        stopPollingIfNeeded()
    }

    func remove(id: UUID) {
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

private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

struct DownloadPanel: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("下载").font(.headline)
                Spacer()
                Button("清除已完成") { store.clearFinished() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(store.downloads.allSatisfy { $0.state == .inProgress })
            }
            .padding(12)

            Divider()

            if store.downloads.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无下载").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.downloads) { item in
                            DownloadRow(item: item, store: store)
                            if item.id != store.downloads.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 420)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var store: DownloadStore

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .lineLimit(1)
                    .font(.system(size: 13))
                if item.state == .inProgress {
                    ProgressView(value: item.isIndeterminate ? nil : item.progress)
                        .frame(width: 240)
                    HStack(spacing: 4) {
                        if item.isIndeterminate {
                            Text("下载中…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(formatBytes(item.downloadedBytes)) / \(formatBytes(item.totalBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("· \(Int((item.progress * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if item.state == .failed {
                    Text(item.error ?? "下载失败")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(formatBytes(item.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailingButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.state {
        case .inProgress:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title3)
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        switch item.state {
        case .inProgress:
            Button {
                store.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .completed:
            HStack(spacing: 12) {
                Button { store.openFile(item) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }.buttonStyle(.plain).help("打开")
                Button { store.revealInFinder(item) } label: {
                    Image(systemName: "folder")
                }.buttonStyle(.plain).help("在 Finder 中显示")
                Button { store.remove(id: item.id) } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("从列表移除")
            }
            .foregroundStyle(.secondary)
        case .failed:
            Button { store.remove(id: item.id) } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
