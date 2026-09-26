import Combine
import Foundation

@MainActor
class HistoryStore: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    /// 云同步待删清单（tombstone），模式同 BookmarkStore.pendingDeletions。
    /// 只记**用户显式删除**（单删/清空/按域删/按时间删）；滚动裁剪与合并溢出
    /// 不产生墓碑——历史是日志型数据，服务端 90 天 TTL 兜底收敛。
    @Published private(set) var pendingDeletions: [UUID: Date] = [:]
    /// DiskStore key (file: App Support/Desire/storage/history.json).
    private let storageKey = "history"
    private let deletionsKey = "history.deletions"
    /// Profile 作用域（0.3.5），模式同 BookmarkStore。
    private var scopeID: UUID?
    private var scopedKey: String {
        guard let scopeID else { return storageKey }
        return storageKey + "." + scopeID.uuidString
    }
    private var scopedDeletionsKey: String {
        guard let scopeID else { return deletionsKey }
        return deletionsKey + "." + scopeID.uuidString
    }
    /// Legacy UserDefaults key — read once during migration, then deleted.
    private let legacyKey = "desire.history"
    private let maxEntries = 500

    init() {
        load()
    }

    func addEntry(url: String, title: String) {
        let entry = HistoryEntry(id: UUID(), url: url, title: title,
                                 timestamp: Date(), updatedAt: Date())
        entries.insert(entry, at: 0)
        // 滚动裁剪：被挤出最旧的条目**不**记墓碑（日志型数据，见 pendingDeletions 注释）
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    /// Corrects the title of the most recent entry for `url`. WebKit's
    /// title KVO lands AFTER didFinish, so entries were being recorded with
    /// the stale placeholder title ("Desire") for fast-titling pages.
    func updateEntryTitle(url: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = entries.firstIndex(where: { $0.url == url }) else { return }
        // 标题校正是一次真实编辑：盖新戳（否则远端/本地同戳不更新）
        entries[idx].title = trimmed
        entries[idx].updatedAt = Date()
        save()
    }

    func removeEntry(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            // 已不在列表（可能先被裁剪）：仍要补记墓碑，服务器上的行才能删掉
            pendingDeletions[id] = Date()
            saveDeletions()
            return
        }
        entries.remove(at: idx)
        pendingDeletions[id] = Date()
        save()
    }

    func recentEntries(count: Int) -> [HistoryEntry] {
        Array(entries.prefix(count))
    }

    func clearAll() {
        let now = Date()
        for entry in entries { pendingDeletions[entry.id] = now }
        entries.removeAll()
        save()
    }

    func removeAll(from domain: String) {
        let now = Date()
        var removed = false
        entries.removeAll { entry in
            guard let url = URL(string: entry.url), let host = url.host else { return false }
            let hit = host == domain || host.hasSuffix(".\(domain)")
            if hit { pendingDeletions[entry.id] = now; removed = true }
            return hit
        }
        if removed { save() }
    }

    func removeAll(before date: Date) {
        let now = Date()
        var removed = false
        entries.removeAll { entry in
            if entry.timestamp < date { pendingDeletions[entry.id] = now; removed = true; return true }
            return false
        }
        if removed { save() }
    }

    func removeAll(after date: Date) {
        let now = Date()
        var removed = false
        entries.removeAll { entry in
            if entry.timestamp >= date { pendingDeletions[entry.id] = now; removed = true; return true }
            return false
        }
        if removed { save() }
    }

    // MARK: - 云同步（SyncStore 调用；合并逻辑在 SyncMerge.HistorySync，纯逻辑可测）

    /// 远端合并结果落地：整表替换、**不盖戳、不裁剪**（合并可能短暂超出
    /// maxEntries，由下一次本地写入自然收敛；这里的行都已在服务器有 LWW 戳）。
    func replaceForSync(_ merged: [HistoryEntry]) {
        entries = merged
        save()
    }

    /// push 裁决（applied/conflict 都算服务端权威）后清已裁决的墓碑。
    func clearPendingDeletions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { pendingDeletions.removeValue(forKey: id) }
        saveDeletions()
    }

    // MARK: - 持久化

    private func load() {
        // Migrated store: read from DiskStore first.
        if let decoded = DiskStore.load([HistoryEntry].self, key: storageKey) {
            entries = Self.normalize(decoded)
        } else if let data = UserDefaults.standard.data(forKey: legacyKey),
                  let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            // One-time migration from legacy UserDefaults blob.
            entries = Self.normalize(decoded)
            DiskStore.save(entries, key: storageKey)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        pendingDeletions = DiskStore.load([UUID: Date].self, key: deletionsKey) ?? [:]
    }

    /// 旧文件的 updatedAt 缺键（nil）→ 用 timestamp 兜底归一，避免 LWW 退化为 .distantPast。
    private static func normalize(_ list: [HistoryEntry]) -> [HistoryEntry] {
        list.map { $0.updatedAt == nil ? HistoryEntry(id: $0.id, url: $0.url, title: $0.title,
                                                      timestamp: $0.timestamp, updatedAt: $0.timestamp)
                       : $0 }
    }

    private func save() {
        DiskStore.save(entries, key: scopedKey)
        saveDeletions()
    }

    private func saveDeletions() {
        DiskStore.save(pendingDeletions, key: scopedDeletionsKey)
    }

    /// AppState.applyProfile 驱动（0.3.5）。
    func applyScope(profileID: UUID?) {
        guard scopeID != profileID else { return }
        save()
        scopeID = profileID
        entries = Self.normalize(DiskStore.load([HistoryEntry].self, key: scopedKey) ?? [])
        pendingDeletions = DiskStore.load([UUID: Date].self, key: scopedDeletionsKey) ?? [:]
    }
}
