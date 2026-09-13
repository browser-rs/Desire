import Combine
import Foundation

@MainActor
class SearchHistoryStore: ObservableObject {
    @Published var entries: [SearchHistory] = []
    /// DiskStore key (file: App Support/Desire/storage/search-history.json).
    private let storageKey = "search-history"
    /// Legacy UserDefaults key — read once during migration, then deleted.
    private let legacyKey = "desire.searchHistory"
    private let maxEntries = 100

    init() {
        load()
    }

    func add(query: String, engine: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = SearchHistory(query: query, engine: engine)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func recentQueries(count: Int) -> [String] {
        Array(entries.prefix(count).map { $0.query })
    }

    private func load() {
        if let decoded = DiskStore.load([SearchHistory].self, key: storageKey) {
            entries = decoded
            return
        }
        // One-time migration from legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([SearchHistory].self, from: data) {
            entries = decoded
            DiskStore.save(decoded, key: storageKey)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    private func save() {
        DiskStore.save(entries, key: storageKey)
    }
}