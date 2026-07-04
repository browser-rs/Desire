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
