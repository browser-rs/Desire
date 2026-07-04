import Combine
import Foundation

@MainActor
class Settings: ObservableObject {
    @Published var searchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: "searchEngine") }
    }
    @Published var homePage: String {
        didSet { UserDefaults.standard.set(homePage, forKey: "homePage") }
    }
    @Published var isJavaScriptEnabled: Bool {
        didSet { UserDefaults.standard.set(isJavaScriptEnabled, forKey: "isJavaScriptEnabled") }
    }
    @Published var showSearchSuggestions: Bool {
        didSet { UserDefaults.standard.set(showSearchSuggestions, forKey: "showSearchSuggestions") }
    }
    @Published var customEngines: [CustomSearchEngine] {
        didSet { saveCustomEngines() }
    }
    @Published var selectedCustomEngineId: UUID? {
        didSet { UserDefaults.standard.set(selectedCustomEngineId?.uuidString, forKey: "selectedCustomEngineId") }
    }

    private let customEnginesKey = "desire.customSearchEngines"

    init() {
        searchEngine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
        homePage = UserDefaults.standard.string(forKey: "homePage") ?? "https://www.google.com"
        isJavaScriptEnabled = UserDefaults.standard.object(forKey: "isJavaScriptEnabled") as? Bool ?? true
        showSearchSuggestions = UserDefaults.standard.object(forKey: "showSearchSuggestions") as? Bool ?? false
        customEngines = Settings.loadCustomEngines(key: customEnginesKey)
        if let idStr = UserDefaults.standard.string(forKey: "selectedCustomEngineId"),
           let id = UUID(uuidString: idStr) {
            selectedCustomEngineId = customEngines.contains(where: { $0.id == id }) ? id : nil
        } else {
            selectedCustomEngineId = nil
        }
    }

    var searchURLTemplate: String {
        if let id = selectedCustomEngineId,
           let engine = customEngines.first(where: { $0.id == id }) {
            return engine.searchURL
        }
        return searchEngine.searchURL
    }

    var suggestionURLTemplate: String {
        if let id = selectedCustomEngineId,
           let engine = customEngines.first(where: { $0.id == id }),
           !engine.suggestionURL.isEmpty {
            return engine.suggestionURL
        }
        return searchEngine.suggestionURL
    }

    func addCustomEngine(name: String, searchURL: String, suggestionURL: String) {
        let engine = CustomSearchEngine(id: UUID(), name: name, searchURL: searchURL, suggestionURL: suggestionURL)
        customEngines.append(engine)
    }

    func removeCustomEngine(_ id: UUID) {
        customEngines.removeAll { $0.id == id }
    }

    private func saveCustomEngines() {
        if let data = try? JSONEncoder().encode(customEngines) {
            UserDefaults.standard.set(data, forKey: customEnginesKey)
        }
    }

    private static func loadCustomEngines(key: String) -> [CustomSearchEngine] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let engines = try? JSONDecoder().decode([CustomSearchEngine].self, from: data) else { return [] }
        return engines
    }
}
