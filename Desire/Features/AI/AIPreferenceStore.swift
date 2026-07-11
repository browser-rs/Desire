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

    /// Which model backend the agent loop talks to. Persisted so the user's
    /// choice survives relaunch. See `ModelProviderKind` for the options.
    @Published var providerKind: ModelProviderKind {
        didSet { UserDefaults.standard.set(providerKind.rawValue, forKey: "aiProviderKind") }
    }

    /// Ollama server base URL. Only used when `providerKind == .ollama`.
    @Published var ollamaHost: String {
        didSet { UserDefaults.standard.set(ollamaHost, forKey: "aiOllamaHost") }
    }

    /// Ollama model name (e.g. `llama3.2`, `qwen2.5`). Only used when
    /// `providerKind == .ollama`.
    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "aiOllamaModel") }
    }

    /// The model backend instance matching `providerKind`. Computed (not
    /// stored) so changing the kind immediately takes effect on the next
    /// agent loop iteration. All providers are stateless value types, so
    /// constructing one per access is free.
    ///
    /// Note: `.routing` constructs a `RoutingProvider` WITHOUT an
    /// `onDecision` callback — used by external callers that don't need the
    /// "via ..." label. `AISessionStore` builds its own `RoutingProvider`
    /// with a callback via `activeProvider` so the UI can show which model
    /// each call used.
    var provider: any ModelProvider {
        switch providerKind {
        case .cloud:            return CloudOpenAIProvider()
        case .foundationModels: return FoundationModelsProvider()
        case .ollama:           return OllamaProvider()
        case .routing:          return RoutingProvider(prefs: self) { _ in }
        }
    }

    /// Session-sticky lock used by `RoutingProvider`. Once a conversation
    /// turns to tool use, all subsequent calls must go to a tool-capable
    /// provider (Foundation Models is text-only and would choke on tool
    /// messages). Non-persistent — resets every app launch. Mutated by
    /// `RoutingProvider.decide`, read on every routing call.
    var routingLockedToCloud = false

    private let keychainService = "me.siwi.Desire"
    private let keychainAccount = "ai-api-key"

    init() {
        // Initialize all stored @Published properties before calling any
        // self method (loadAPIKey) — Swift requires full initialization first.
        model = UserDefaults.standard.string(forKey: "aiModel") ?? "gpt-4o"
        endpoint = UserDefaults.standard.string(forKey: "aiEndpoint") ?? "https://api.openai.com/v1"
        systemPrompt = UserDefaults.standard.string(forKey: "aiSystemPrompt") ?? Self.defaultPrompt
        maxTokens = UserDefaults.standard.object(forKey: "aiMaxTokens") as? Int ?? 4096
        temperature = UserDefaults.standard.object(forKey: "aiTemperature") as? Double ?? 0.7

        if let savedKind = UserDefaults.standard.string(forKey: "aiProviderKind"),
           let kind = ModelProviderKind(rawValue: savedKind) {
            providerKind = kind
        } else {
            providerKind = .cloud
        }
        ollamaHost = UserDefaults.standard.string(forKey: "aiOllamaHost") ?? "http://localhost:11434/v1"
        ollamaModel = UserDefaults.standard.string(forKey: "aiOllamaModel") ?? "llama3.2"

        // Now fully initialized — safe to call self methods.
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

/// Selectable model backends for the AI assistant.
///
/// - `.cloud`: OpenAI-compatible cloud API (OpenAI, OpenRouter, DeepSeek, …).
///   Requires an API key and network. Full tool-calling support.
/// - `.foundationModels`: Apple Foundation Models on-device (macOS 26+,
///   Apple Intelligence). Zero network, full privacy. Text-only in stage 1;
///   tool calling lands with AgentRuntime v2.
/// - `.ollama`: Local Ollama server (`http://localhost:11434`). OpenAI-
///   compatible, full tool-calling support, user must run Ollama + pull a model.
/// - `.routing`: Automatic per-task routing via `RoutingProvider`. Summaries
///   and translations run on-device when available; complex actions and tool
///   chains run in the cloud. The chosen model is shown as a "via ..." label.
enum ModelProviderKind: String, CaseIterable, Codable {
    case cloud
    case foundationModels
    case ollama
    case routing

    /// Short label for the "via ..." indicator in the AI panel. Keep these
    /// concise since they render inline next to the assistant response.
    var viaLabel: String {
        switch self {
        case .cloud:            "Cloud"
        case .foundationModels: "On-device"
        case .ollama:           "Ollama"
        case .routing:          "Auto"
        }
    }

    var displayName: String {
        switch self {
        case .cloud:            "Cloud (OpenAI-compatible)"
        case .foundationModels: "Apple Foundation Models (on-device)"
        case .ollama:           "Ollama (local server)"
        case .routing:          "Auto (route automatically)"
        }
    }

    var detail: String {
        switch self {
        case .cloud:            "Requires API key. Supports browser tools."
        case .foundationModels: "No key, no network. Privacy-first. Text only (no tools yet)."
        case .ollama:           "Runs locally via Ollama. Supports browser tools."
        case .routing:          "Picks the best model per task: on-device for summaries/translations, cloud for complex actions."
        }
    }
}

