import Combine
import Foundation

@MainActor
class TabGroupStore: ObservableObject {
    @Published var groups: [TabGroup] = []

    private let storageKey = "desire.tabGroups"

    init() { load() }

    func create(name: String, colorIndex: Int = 0) -> TabGroup {
        let group = TabGroup(id: UUID(), name: name, colorIndex: colorIndex, tabIds: [])
        groups.append(group)
        save()
        return group
    }

    func addTab(_ tabId: UUID, to groupId: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        for i in groups.indices { groups[i].tabIds.remove(tabId) }
        groups[idx].tabIds.insert(tabId)
        save()
    }

    func removeTab(_ tabId: UUID, from groupId: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].tabIds.remove(tabId)
        save()
    }

    func removeTabFromAll(_ tabId: UUID) {
        for i in groups.indices { groups[i].tabIds.remove(tabId) }
        save()
    }

    func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    func group(for tabId: UUID) -> TabGroup? {
        groups.first { $0.tabIds.contains(tabId) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TabGroup].self, from: data) else { return }
        groups = decoded
    }
}
