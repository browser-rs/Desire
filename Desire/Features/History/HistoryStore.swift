import Combine
import Foundation

@MainActor
class HistoryStore: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    private let saveKey = "desire.history"
    private let maxEntries = 500

    init() {
        load()
    }

    func addEntry(url: String, title: String) {
        let entry = HistoryEntry(id: UUID(), url: url, title: title, timestamp: Date())
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func recentEntries(count: Int) -> [HistoryEntry] {
        Array(entries.prefix(count))
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func removeAll(from domain: String) {
        entries.removeAll { entry in
            guard let url = URL(string: entry.url), let host = url.host else { return false }
            return host == domain || host.hasSuffix(".\(domain)")
        }
        save()
    }

    func removeAll(before date: Date) {
        entries.removeAll { $0.timestamp < date }
        save()
    }

    func removeAll(after date: Date) {
        entries.removeAll { $0.timestamp >= date }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }
}
