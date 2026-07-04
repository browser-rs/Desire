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

    init() {
        searchEngine = SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
        homePage = UserDefaults.standard.string(forKey: "homePage") ?? "https://www.google.com"
        isJavaScriptEnabled = UserDefaults.standard.object(forKey: "isJavaScriptEnabled") as? Bool ?? true
        showSearchSuggestions = UserDefaults.standard.object(forKey: "showSearchSuggestions") as? Bool ?? false
    }

    var searchURLTemplate: String {
        searchEngine.searchURL
    }
}
