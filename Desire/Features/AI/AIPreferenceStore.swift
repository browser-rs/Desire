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

    /// Identifies the active cloud provider ("openai", "deepseek", "zhipu",
    /// "opencode-go", or a custom id). Used to select the per-provider API
    /// key from Keychain and to resolve preset endpoint/model values.
    @Published var cloudProviderID: String {
        didSet { UserDefaults.standard.set(cloudProviderID, forKey: "aiCloudProviderID") }
    }

    /// Saved endpoint profiles — each is a self-contained {name, url, model}
    /// combo. Users add one per model/service combo they use (e.g. "GLM-4
    /// Plus via Zhipu", "GPT-4o via OpenCode Go"). Switching profiles copies
    /// the URL + model into the active endpoint/model fields.
    @Published var savedEndpoints: [SavedAIEndpoint] {
        didSet { DiskStore.save(savedEndpoints, key: "aiSavedEndpoints") }
    }
    /// Which saved endpoint is active (drives the AI's actual API calls).
    @Published var activeEndpointID: UUID? {
        didSet { UserDefaults.standard.set(activeEndpointID?.uuidString, forKey: "aiActiveEndpointID") }
    }

    /// The active saved endpoint, if any. When set, `endpoint` and `model`
    /// delegates to this entry's values.
    var activeSavedEndpoint: SavedAIEndpoint? {
        guard let id = activeEndpointID else { return nil }
        return savedEndpoints.first(where: { $0.id == id })
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

    /// Tools the user has whitelisted with "Always Allow". Persisted across
    /// launches. `.dangerous` tools are never honored here — they always
    /// prompt. Consolidates the `aiAllowedTools` UserDefaults key that
    /// previously lived on `AISessionStore`.
    /// - Note: stored as a native `[String]` via UserDefaults (not DiskStore
    ///   JSON) because the array is small and benefits from live-read without
    ///   async overhead in the agent's risk-gating hot path.
    @Published var allowedTools: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(allowedTools), forKey: "aiAllowedTools")
        }
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
    /// Legacy single-key account — checked once during migration.
    private let legacyKeychainAccount = "ai-api-key"

    /// Keychain account for the ACTIVE cloud provider. Each provider gets
    /// its own key so switching providers switches the credential too.
    private var keychainAccount: String { "ai-key-" + cloudProviderID }

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
        ollamaModel = UserDefaults.standard.string(forKey: "aiOllamaModel") ?? "llama3.2"
        allowedTools = Set(UserDefaults.standard.stringArray(forKey: "aiAllowedTools") ?? [])
        cloudProviderID = UserDefaults.standard.string(forKey: "aiCloudProviderID") ?? "openai"
        savedEndpoints = DiskStore.load([SavedAIEndpoint].self, key: "aiSavedEndpoints") ?? []
        activeEndpointID = UserDefaults.standard.string(forKey: "aiActiveEndpointID").flatMap { UUID(uuidString: $0) }

        // Legacy migration: if the old single "ai-api-key" exists and no
        // per-provider key has been saved yet for the default provider,
        // copy it forward so the upgrade is transparent.
        if loadAPIKey() == nil,
           let legacyKey = keychainRead(account: legacyKeychainAccount),
           let legacyData = legacyKey.data(using: .utf8) {
            keychainWrite(data: legacyData, account: "ai-key-openai")
            keychainDelete(account: legacyKeychainAccount)
        }

        // Now fully initialized — safe to call self methods.
        hasAPIKey = loadAPIKey() != nil
    }

    func loadAPIKey() -> String? {
        keychainRead(account: keychainAccount)
    }

    func saveAPIKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        keychainWrite(data: data, account: keychainAccount)
        hasAPIKey = true
    }

    func deleteAPIKey() {
        keychainDelete(account: keychainAccount)
        hasAPIKey = false
    }

    // MARK: - Keychain primitives

    private func keychainRead(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    private func keychainWrite(data: Data, account: String) {
        keychainDelete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static let defaultPrompt = """
你是 Desire 浏览器的 AI 助手。你可以控制浏览器完成各种操作。

## 核心规则
- 用户说"打开XX"或"去XX" → 调用 navigate 工具导航到对应网站
- 用户说"搜索XX" → 拼接搜索 URL 后调用 navigate（如 https://www.google.com/search?q=XX）
- 用户说"看看当前页面" → 调用 getPageSnapshot 获取结构化内容
- 用户说"点击XX按钮" → 先用 getPageSnapshot 找到元素，再用 click(selector) 点击
- 不要调用 getPageHTML 除非用户明确要求看源代码

## 可用工具速查
- navigate(url) — 导航到指定网址
- getPageSnapshot — 获取当前页面的文字内容和可交互元素（首选读取方式）
- getPageText — 获取当前页面的纯文字
- click(selector) — 点击元素（CSS 选择器）
- clickAt(x, y) — 按坐标点击（配合 screenshot 使用）
- screenshot — 截取当前页面截图（视觉模型可直接看到）
- fill(selector, value) — 填写表单输入框
- newTab(url) — 新标签页打开网址
- listTabs — 列出所有打开的标签页
- searchEngine — 当前使用的搜索引擎

## 注意事项
- 用户说"打开bilibili"就是导航到 bilibili.com，不要去读取页面源码
- 每个操作完成后简要告知用户结果
- 遇到错误时告知用户原因
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



/// A saved AI provider configuration (endpoint + model combo).
/// Persisted via DiskStore alongside the AIPreferenceStore.
struct SavedAIEndpoint: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var model: String

    init(id: UUID = UUID(), name: String, url: String, model: String) {
        self.id = id
        self.name = name
        self.url = url
        self.model = model
    }
}
