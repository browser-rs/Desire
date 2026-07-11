import Combine
import Foundation
import Security

@MainActor
class AIPreferenceStore: ObservableObject {
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "aiModel") }
    }
    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: "aiEndpoint") }
    }
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "aiSystemPrompt") }
    }
    @Published var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: "aiMaxTokens") }
    }
    @Published var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: "aiTemperature") }
    }
    @Published var hasAPIKey: Bool = false

    /// The model backend the agent loop talks to. Defaults to the cloud
    /// OpenAI-compatible provider; future providers (Foundation Models,
    /// Ollama, a rule-based router) replace this instance. Reading is
    /// nonisolated-safe because the property is only mutated on MainActor
    /// and the agent loop captures it before firing its Task.
    var provider: any ModelProvider = CloudOpenAIProvider()

    private let keychainService = "me.siwi.Desire"
    private let keychainAccount = "ai-api-key"

    init() {
        model = UserDefaults.standard.string(forKey: "aiModel") ?? "gpt-4o"
        endpoint = UserDefaults.standard.string(forKey: "aiEndpoint") ?? "https://api.openai.com/v1"
        systemPrompt = UserDefaults.standard.string(forKey: "aiSystemPrompt") ?? Self.defaultPrompt
        maxTokens = UserDefaults.standard.object(forKey: "aiMaxTokens") as? Int ?? 4096
        temperature = UserDefaults.standard.object(forKey: "aiTemperature") as? Double ?? 0.7
        hasAPIKey = loadAPIKey() != nil
    }

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    func saveAPIKey(_ key: String) {
        deleteAPIKey()
        guard let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
        hasAPIKey = true
    }

    func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        hasAPIKey = false
    }

    static let defaultPrompt = """
You are an AI assistant integrated into the Desire browser. You can:
- Read the current page content and structure
- Navigate to URLs, click elements, fill forms, scroll
- Extract data and execute JavaScript
- Take screenshots of the viewport

When the user asks you to do something, use the available tools. Always explain what you're doing. Prefer non-destructive actions.
"""
}
