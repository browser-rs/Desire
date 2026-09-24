import Combine
import Foundation

@MainActor
class QuickDialStore: ObservableObject {
    @Published var dials: [QuickDial] = []
    private let storageKey = "desire.quickdials"
    /// Profile 作用域（0.3.5），模式同 BookmarkStore。
    private var scopeID: UUID?
    private var scopedKey: String {
        guard let scopeID else { return storageKey }
        return storageKey + "." + scopeID.uuidString
    }
    /// 云同步待删清单（tombstone），模式同 BookmarkStore.pendingDeletions。
    @Published private(set) var pendingDeletions: [UUID: Date] = [:]
    private let deletionsKey = "desire.quickdials.deletions"
    private var scopedDeletionsKey: String {
        guard let scopeID else { return deletionsKey }
        return deletionsKey + "." + scopeID.uuidString
    }

    init() {
        load()
    }

    func add(title: String, url: String) {
        var dial = QuickDial(title: title, url: url, sort: dials.count)
        dial.updatedAt = Date()
        dials.append(dial)
        save()
    }

    func delete(id: UUID) {
        dials.removeAll { $0.id == id }
        pendingDeletions[id] = Date()
        saveDeletions()
        renumberSort()
        save()
    }

    func update(id: UUID, title: String, url: String) {
        guard let index = dials.firstIndex(where: { $0.id == id }) else { return }
        dials[index].title = title
        dials[index].url = url
        dials[index].updatedAt = Date()
        save()
    }

    func move(from source: Int, to destination: Int) {
        guard dials.indices.contains(source), dials.indices.contains(destination) else { return }
        let moved = dials.remove(at: source)
        let insert = source < destination ? destination - 1 : destination
        dials.insert(moved, at: min(insert, dials.count))
        // 位移即结构变更：全部重编号并盖戳——否则被挤动条目的新 sort 会因
        // 时间戳未变被远端 LWW 拒收，跨设备顺序分叉。
        renumberSort(stamping: true)
        save()
    }

    /// 结构变更后重编号 0..n；stamping = 把编号变化的条目补盖同步戳。
    private func renumberSort(stamping: Bool = false) {
        let before = Dictionary(dials.enumerated().map { ($1.id, $1.sort) },
                                uniquingKeysWith: { a, _ in a })
        let now = Date()
        for i in dials.indices {
            dials[i].sort = i
            if stamping, before[dials[i].id] != i {
                dials[i].updatedAt = now
            }
        }
    }

    private func load() {
        if let decoded = DiskStore.load([QuickDial].self, key: storageKey), !decoded.isEmpty {
            dials = normalizeTimestamps(decoded)
            pendingDeletions = DiskStore.load([UUID: Date].self, key: deletionsKey) ?? [:]
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([QuickDial].self, from: data),
           !decoded.isEmpty {
            dials = normalizeTimestamps(decoded)
            save()
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        dials = normalizeTimestamps(defaultDials)
    }

    private func save() {
        DiskStore.save(dials, key: scopedKey)
    }

    /// AppState.applyProfile 驱动（0.3.5）。新桶为空回退默认快拨。
    func applyScope(profileID: UUID?) {
        guard scopeID != profileID else { return }
        save()
        scopeID = profileID
        dials = normalizeTimestamps(DiskStore.load([QuickDial].self, key: scopedKey) ?? defaultDials)
        pendingDeletions = DiskStore.load([UUID: Date].self, key: scopedDeletionsKey) ?? [:]
    }

    // MARK: - 云同步（SyncStore 驱动）

    /// 同步合并结果整表替换（LWW 仲裁已在合并层完成），按 sort 重排并重编号。
    func replaceForSync(_ replaced: [QuickDial]) {
        dials = replaced.sorted { $0.sort < $1.sort }
        renumberSort()
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
        DiskStore.save(pendingDeletions, key: scopedDeletionsKey)
    }

    private func normalizeTimestamps(_ list: [QuickDial]) -> [QuickDial] {
        let now = Date()
        var out = list.map { item -> QuickDial in
            var copy = item
            if copy.updatedAt == nil { copy.updatedAt = now }
            return copy
        }
        // 旧数据 sort 可能缺失/错乱：按现有顺序重编号
        for i in out.indices { out[i].sort = i }
        return out
    }
}
