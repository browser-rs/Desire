import Combine
import Foundation

@MainActor
class ReadingListStore: ObservableObject {
    @Published var items: [ReadingListItem] = []

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
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ReadingListItem].self, from: data) else { return }
        items = decoded
    }
}
