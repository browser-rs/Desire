import Combine
import Foundation

@MainActor
class HistoryStore: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    /// DiskStore key (file: App Support/Desire/storage/history.json).
    private let storageKey = "history"
    /// Legacy UserDefaults key — read once during migration, then deleted.
    private let legacyKey = "desire.history"
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

    /// Corrects the title of the most recent entry for `url`. WebKit's
    /// title KVO lands AFTER didFinish, so entries were being recorded with
    /// the stale placeholder title ("Desire") for fast-titling pages.
    func updateEntryTitle(url: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = entries.firstIndex(where: { $0.url == url }) else { return }
        entries[idx] = HistoryEntry(
            id: entries[idx].id, url: entries[idx].url,
            title: trimmed, timestamp: entries[idx].timestamp
        )
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
        // Migrated store: read from DiskStore first.
        if let decoded = DiskStore.load([HistoryEntry].self, key: storageKey) {
            entries = decoded
            return
        }
        // One-time migration from legacy UserDefaults blob. If present,
        // import it to DiskStore and remove the old key so we never read
        // stale data again.
        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
            DiskStore.save(decoded, key: storageKey)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    private func save() {
        DiskStore.save(entries, key: storageKey)
    }
}
