import Combine
import Foundation

@MainActor
class ElementBlockStore: ObservableObject {
    @Published var rules: [BlockedElementRule] = []

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
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([BlockedElementRule].self, from: data) else { return }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }
}
