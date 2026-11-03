import Combine
import Foundation

/// 最近关闭标签的持久化账本（v0.8.40）：跨窗口、跨启动保留，
/// RecentlyClosedPanel 与「恢复整窗」共用。⌘⇧T 仍走 TabManager 的窗口内队列。
nonisolated struct RecentlyClosedEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var url: String
    var title: String
    var isIncognito: Bool
    var containerID: UUID?
    var closedAt: Date
}

@MainActor
final class RecentlyClosedStore: ObservableObject {
    static let shared = RecentlyClosedStore()

    @Published private(set) var entries: [RecentlyClosedEntry] = []

    private static let key = "recentlyClosed.v2"
    private static let cap = 50

    private init() {
        entries = (DiskStore.load([RecentlyClosedEntry].self, key: Self.key) ?? [])
            .sorted { $0.closedAt > $1.closedAt }
    }

    func record(url: String, title: String, isIncognito: Bool,
                containerID: UUID?) {
        guard !url.isEmpty, !isIncognito else { return }
        // 连续关闭同一 URL（刷新/误点重复）只保留一条。
        if let first = entries.first, first.url == url { return }
        entries.insert(RecentlyClosedEntry(
            id: UUID(), url: url,
            title: title.isEmpty ? url : title,
            isIncognito: false, containerID: containerID,
            closedAt: Date()), at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    func search(_ query: String) -> [RecentlyClosedEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q)
        }
    }

    private func persist() {
        DiskStore.save(entries, key: Self.key)
    }
}
