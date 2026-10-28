import Combine
import Foundation

/// 命名数据集规格（v0.8.20 融合 12）：保存过的采集配置（start URL/字段/
/// 翻页），供定时采集与复用。DiskStore 持久化；id 由生成方赋值。
@MainActor
final class DatasetSpecStore: ObservableObject {

    struct NamedSpec: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var spec: DatasetSpec
    }

    static let shared = DatasetSpecStore()

    private static let storeKey = "dataset-named-specs"

    @Published private(set) var specs: [NamedSpec] = []   // 新在前

    private init() {
        specs = DiskStore.load([NamedSpec].self, key: Self.storeKey) ?? []
    }

    private func save() {
        DiskStore.save(specs, key: Self.storeKey)
    }

    @discardableResult
    func save(name: String, spec: DatasetSpec) -> NamedSpec {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let named: NamedSpec
        if let existing = specs.first(where: { $0.name == trimmed }) {
            named = NamedSpec(id: existing.id, name: trimmed, spec: spec)
            if let idx = specs.firstIndex(where: { $0.id == existing.id }) {
                specs[idx] = named
            }
        } else {
            named = NamedSpec(id: UUID(), name: trimmed, spec: spec)
            specs.insert(named, at: 0)
        }
        save()
        return named
    }

    func remove(id: UUID) {
        specs.removeAll { $0.id == id }
        save()
    }

    func spec(id: UUID) -> NamedSpec? {
        specs.first { $0.id == id }
    }
}
