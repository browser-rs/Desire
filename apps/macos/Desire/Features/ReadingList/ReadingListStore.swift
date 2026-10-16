import Combine
import Foundation

@MainActor
class ReadingListStore: ObservableObject {
    @Published var items: [ReadingListItem] = []

    /// 离线缓存目录（.webarchive；机器本地，不随同步走）。
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Desire/ReadingListCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let storageKey = "desire.readingList"
    /// 云同步待删清单（tombstone），模式同 BookmarkStore.pendingDeletions。
    @Published private(set) var pendingDeletions: [UUID: Date] = [:]
    private let deletionsKey = "desire.readingList.deletions"

    init() {
        load()
    }

    func add(title: String, url: String) {
        guard !url.isEmpty else { return }
        if items.contains(where: { $0.url == url }) { return }
        var item = ReadingListItem(id: UUID(), title: title, url: url, savedDate: Date(), isRead: false)
        item.updatedAt = Date()
        items.insert(item, at: 0)
        save()
    }

    func remove(at offsets: IndexSet) {
        let ids = offsets.map { items[$0].id }
        for id in ids { remove(id) }
    }

    func toggleRead(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isRead.toggle()
        items[index].updatedAt = Date()
        save()
    }

    func remove(_ id: UUID) {
        deleteCacheFile(id)
        items.removeAll { $0.id == id }
        pendingDeletions[id] = Date()
        saveDeletions()
        save()
    }

    /// 写入批量摘要（v0.7.19）：盖 LWW 戳让摘要随云同步走。
    func setSummary(_ id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items[index].summary = trimmed
        items[index].summarizedAt = Date()
        items[index].updatedAt = Date()
        save()
    }

    // MARK: - 离线缓存

    /// 缓存的 webarchive 落定（capture 成功后调用）。
    func setCache(_ id: UUID, fileURL: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteCacheFile(id)   // 重缓存：先清旧的
        items[index].cachedFile = fileURL.path
        items[index].cachedAt = Date()
        save()
    }

    /// 移除离线副本（文件 + 字段）。
    func clearCache(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        deleteCacheFile(id)
        items[index].cachedFile = nil
        items[index].cachedAt = nil
        save()
    }

    /// 条目是否有可用的离线副本（文件真实存在才算）。
    func cacheURL(for id: UUID) -> URL? {
        guard let item = items.first(where: { $0.id == id }),
              let path = item.cachedFile,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func deleteCacheFile(_ id: UUID) {
        guard let path = items.first(where: { $0.id == id })?.cachedFile else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    func clearAll() {
        // 批量 tombstone：清空必须逐条下推，否则其他设备会把条目同步回来。
        let now = Date()
        for item in items { pendingDeletions[item.id] = now }
        for item in items { deleteCacheFile(item.id) }   // 离线副本一并清
        items.removeAll()
        saveDeletions()
        save()
    }

    private func save() {
        DiskStore.save(items, key: storageKey)
    }

    private func load() {
        if let decoded = DiskStore.load([ReadingListItem].self, key: storageKey) {
            items = normalizeTimestamps(decoded)
            pendingDeletions = DiskStore.load([UUID: Date].self, key: deletionsKey) ?? [:]
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ReadingListItem].self, from: data) {
            items = normalizeTimestamps(decoded)
            save()
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    // MARK: - 云同步（SyncStore 驱动）

    /// 同步合并结果整表替换，并按 savedDate 重排（列表序 = 最近保存在前，
    /// payload 不携带 sort，避免下标位移引发的连锁盖戳）。
    func replaceForSync(_ replaced: [ReadingListItem]) {
        items = replaced.sorted { $0.savedDate > $1.savedDate }
        save()
    }

    /// push 成功后从待删清单移除（clientIDs = 服务端已 applied 的条目）。
    func clearPendingDeletions(_ clientIDs: Set<String>) {
        let hits = pendingDeletions.keys.filter { clientIDs.contains($0.uuidString) }
        guard !hits.isEmpty else { return }
        for id in hits { pendingDeletions.removeValue(forKey: id) }
        saveDeletions()
    }

    private func saveDeletions() {
        DiskStore.save(pendingDeletions, key: deletionsKey)
    }

    private func normalizeTimestamps(_ list: [ReadingListItem]) -> [ReadingListItem] {
        let now = Date()
        return list.map { item in
            var out = item
            if out.updatedAt == nil { out.updatedAt = now }
            return out
        }
    }
}
