import Combine
import Foundation

@MainActor
class PermissionStore: ObservableObject {
    @Published private(set) var rules: [PermissionRule] = []

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let key = "desire.permissionRules"

    init() {
        if let decoded = DiskStore.load([PermissionRule].self, key: key) {
            rules = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PermissionRule].self, from: data) {
            rules = decoded
            save()
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func decision(for host: String, type: PermissionType) -> PermissionDecision? {
        rules.first(where: { $0.host == host && $0.type == type })?.decision
    }

    func set(host: String, type: PermissionType, decision: PermissionDecision) {
        rules.removeAll { $0.host == host && $0.type == type }
        rules.append(PermissionRule(host: host, type: type, decision: decision))
        save()
    }

    func remove(host: String) {
        rules.removeAll { $0.host == host }
        save()
    }

    func remove(host: String, type: PermissionType) {
        rules.removeAll { $0.host == host && $0.type == type }
        save()
    }

    func removeAll(type: PermissionType) {
        rules.removeAll { $0.type == type }
        save()
    }

    func removeAll() {
        rules.removeAll()
        save()
    }

    /// 隐私面板矩阵单元格的三态循环写入口（未设置 → 允许 → 拒绝 → 未设置）。
    func cycle(host: String, type: PermissionType) {
        switch PermissionMatrix.cycled(decision(for: host, type: type)) {
        case .some(let d): set(host: host, type: type, decision: d)
        case nil: remove(host: host, type: type)
        }
    }

    private func save() {
        DiskStore.save(rules, key: key)
    }
}
