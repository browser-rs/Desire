import Combine
import Foundation

@MainActor
class ReadingListStore: ObservableObject {
    @Published var items: [ReadingListItem] = []

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let storageKey = "desire.readingList"

    init() {
        load()
    }

    func add(title: String, url: String) {
        guard !url.isEmpty else { return }
        if items.contains(where: { $0.url == url }) { return }
        let item = ReadingListItem(id: UUID(), title: title, url: url, savedDate: Date(), isRead: false)
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
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        items.removeAll()
        save()
    }

    private func save() {
        DiskStore.save(items, key: storageKey)
    }

    private func load() {
        if let decoded = DiskStore.load([ReadingListItem].self, key: storageKey) {
            items = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ReadingListItem].self, from: data) {
            items = decoded
            save()
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }
}
