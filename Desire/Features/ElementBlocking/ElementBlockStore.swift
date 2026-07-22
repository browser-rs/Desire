import Combine
import Foundation

@MainActor
class ElementBlockStore: ObservableObject {
    @Published var rules: [BlockedElementRule] = []

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let saveKey = "desire.elementBlockRules"

    init() { load() }

    func add(cssSelector: String, xpath: String? = nil, urlPattern: String) {
        let rule = BlockedElementRule(urlPattern: urlPattern, cssSelector: cssSelector, xpath: xpath)
        rules.append(rule)
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func matchingRules(for host: String) -> [BlockedElementRule] {
        rules.filter { $0.matches(host: host) }
    }

    private func load() {
        if let decoded = DiskStore.load([BlockedElementRule].self, key: saveKey) {
            rules = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([BlockedElementRule].self, from: data) {
            rules = decoded
            save()
            UserDefaults.standard.removeObject(forKey: saveKey)
        }
    }

    private func save() {
        DiskStore.save(rules, key: saveKey)
    }
}
