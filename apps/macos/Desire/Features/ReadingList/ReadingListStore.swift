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

    // MARK: - 标签（v0.8.25）

    /// 整表替换标签（去空白/去重），盖 LWW 戳随云同步走。
    func setTags(_ tags: [String], for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let normalized = ReadingListTags.normalize(tags)
        if (items[index].tagList.map { $0.lowercased() }) == normalized.map({ $0.lowercased() }) {
            return
        }
        // 空数组 = 用户显式清空（与"旧数据无标签"的 nil 区分，同步侧据此决定
        // 是否覆盖远端标签）。
        items[index].tags = normalized
        items[index].updatedAt = Date()
        save()
    }

    /// 加/删单个标签。
    func toggleTag(_ tag: String, for id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        setTags(ReadingListTags.toggling(tag, in: item.tagList), for: id)
    }

    /// 全部标签（去重、按字母序）。
    func allTags() -> [String] {
        ReadingListTags.all(in: items.map(\.tagList))
    }

    /// 回滚还原：整条按快照重插（保留原 id；同 id 已存在跳过）。
    func restoreForUndo(_ item: ReadingListItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.insert(item, at: 0)
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

    /// 记录阅读进度（0..1，钳位）。**盖 LWW 戳**（updatedAt）——否则同步侧
    /// 的 FlatSyncMerge 会把这次改动当旧值拒收。变化不明显（<1%）不写，
    /// 免得每个 tick 都落盘。
    func setProgress(_ ratio: Double, for url: String) {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        let clamped = min(1.0, max(0.0, ratio))
        if let existing = items[index].progress, abs(existing - clamped) < 0.01 { return }
        items[index].progress = clamped
        items[index].progressAt = Date()
        items[index].updatedAt = Date()
        save()
    }

    /// 该 URL 的记录进度（nil = 无记录）。
    func progress(for url: String) -> Double? {
        items.first { $0.url == url }?.progress
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
