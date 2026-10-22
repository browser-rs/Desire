import Combine
import Foundation
import os

/// 定时下载队列（v0.8.0）：持久化 URL/时间，到点交给 `DownloadStore.live`。
/// 应用关闭期间到点的任务在下次启动后补跑。
@MainActor
final class DownloadScheduler: ObservableObject {
    static let shared = DownloadScheduler()

    @Published private(set) var items: [ScheduledDownload] = []

    private let storageKey = "downloads.scheduled"
    private var timer: Timer?
    private var initialCheck: Task<Void, Never>?

    private init() {
        items = (DiskStore.load([ScheduledDownload].self, key: storageKey) ?? [])
            .sorted { $0.startAt < $1.startAt }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        initialCheck?.cancel()
        initialCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    @discardableResult
    func schedule(url: URL, filename: String?, startAt: Date) -> ScheduledDownload? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        let resolvedName = (filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ScheduledDownload(
            id: UUID(),
            url: url.absoluteString,
            filename: resolvedName.isEmpty ? ScheduledDownload.suggestedFilename(for: url) : resolvedName,
            startAt: startAt,
            createdAt: Date())
        items.append(item)
        items.sort { $0.startAt < $1.startAt }
        save()
        return item
    }

    func cancel(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func cancelAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        save()
    }

    private func tick() {
        guard let store = DownloadStore.live else { return }
        let now = Date()
        let due = items.filter { $0.startAt <= now }
        guard !due.isEmpty else { return }
        for item in due {
            if let url = URL(string: item.url) {
                let started = store.startURLSessionDownload(
                    sourceURL: url, filename: item.filename)
                if !started {
                    Log.downloads.info("scheduled download skipped (duplicate): \(item.url, privacy: .public)")
                }
            }
            items.removeAll { $0.id == item.id }
        }
        save()
    }

    private func save() {
        DiskStore.save(items, key: storageKey)
    }
}
