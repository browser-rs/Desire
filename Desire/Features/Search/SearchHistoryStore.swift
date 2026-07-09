import Combine
import Foundation

@MainActor
class SearchHistoryStore: ObservableObject {
    @Published var entries: [SearchHistory] = []
    private let saveKey = "desire.searchHistory"
    private let maxEntries = 100

    init() {
        load()
    }

    func add(query: String, engine: SearchEngine) {
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
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([SearchHistory].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }
}