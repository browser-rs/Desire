import Combine
import Foundation
import Security

@MainActor
class AgentPreferenceStore: ObservableObject {
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
    /// Background memory learning: auto-extract durable user facts and
    /// per-conversation summaries after agent turns. User-inspectable and
    /// editable in the memory view either way.
    @Published var memoryLearning: Bool {
        didSet { UserDefaults.standard.set(memoryLearning, forKey: "aiMemoryLearning") }
    }
    /// When on, every model request carries an EPHEMERAL compact summary of
    /// the page the agent is working on (title + URL + text excerpt) — so
    /// "这是什么页面" needs no tool roundtrip and every agent step sees the
    /// freshest page state. Not persisted in the conversation.
    @Published var autoPageContext: Bool {
        didSet { UserDefaults.standard.set(autoPageContext, forKey: "aiAutoPageContext") }
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
    /// previously lived on `AgentSessionStore`.
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
    /// "via ..." label. `AgentSessionStore` builds its own `RoutingProvider`
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
        if let stored = UserDefaults.standard.string(forKey: "aiSystemPrompt"),
           !Self.isOutdatedBuiltInPrompt(stored) {
            systemPrompt = stored
        } else {
            systemPrompt = Self.defaultPrompt
        }
        maxTokens = UserDefaults.standard.object(forKey: "aiMaxTokens") as? Int ?? 4096
        autoPageContext = UserDefaults.standard.object(forKey: "aiAutoPageContext") as? Bool ?? true
        memoryLearning = UserDefaults.standard.object(forKey: "aiMemoryLearning") as? Bool ?? true
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

    /// A previously persisted copy of a BUILT-IN default prompt (never
    /// customized by the user). Fingerprinted by tool lines that only ever
    /// existed in our defaults — when matched, the stored value is discarded
    /// so the current default takes effect. User-written prompts are never
    /// touched (they don't contain these exact lines).
    static func isOutdatedBuiltInPrompt(_ prompt: String) -> Bool {
        // v1: only documented the selector-based click tool.
        if prompt.contains("click(selector) — 点击元素（CSS 选择器）") { return true }
        // v2: comment/chat tools present, listed in a longer 速查 block.
        if prompt.contains("getComments — 结构化提取评论区") { return true }
        return false
    }

    static let defaultPrompt = """
你是 Desire 浏览器的 Agent（智能体）。你可以操控浏览器、调用系统工具、使用技能，自主完成各种任务。

## 核心规则
- 用户说"打开XX"或"去XX" → 调用 navigate 工具导航到对应网站
- 复杂/多步任务（转码、合成、安装工具等）→ 先查可用技能，命中就 useSkill 加载手册，再按手册调用 runCommand 执行；系统命令运行前向用户说明要做什么
- 任何 3 步以上的任务 → 先用 updatePlan 建立任务清单，每完成一步就更新状态，让用户实时看到进度
- 用户要求"录制/演示操作过程" → 调用 startRecording 开始录制窗口画面，完成操作步骤后调用 stopRecording 保存到下载文件夹；首次使用需用户在系统设置授予屏幕录制权限
- 用户要发布视频/内容到平台（B站/YouTube/抖音等）→ 命中平台技能先 useSkill 加载手册，然后：setUploadFile 锁定文件 → navigate 打开上传页 → click 上传入口（文件自动提交）→ 填标题/简介/标签 → 提交并验证成功提示
- 关键选择不明确时（发哪个文件、清晰度、定时还是立即）→ 用 askUser(question) 向用户提问并等待回答，提供选项；不要替用户瞎猜
- 用户说"搜索XX" → 拼接搜索 URL 后调用 navigate（如 https://www.google.com/search?q=XX）
- 用户说"看看当前页面" → 调用 getPageSnapshot 获取结构化内容
- 用户说"点击XX按钮" → 优先 click(ref) 用快照里的编号；快照没有就用 click(text: "按钮文字")；CSS 选择器是最后手段
- 用户说"总结评论 / 评论区在说什么" → 调用 getComments
- 用户说"总结对话 / 这个聊天说了什么" → 调用 getConversation
- 用户说"帮我评论 / 回复 / 发消息" → 先读内容（getComments/getConversation），再调用 postComment 发送
- 不要调用 getPageHTML 除非用户明确要求看源代码

## 可用工具速查
- navigate(url) — 导航到指定网址
- getPageSnapshot — 获取当前页面的文字内容和可交互元素（首选读取方式）
- getPageLinks — 提取页面所有可见链接（规划"该点哪个链接"时用）
- getFormFields — 提取表单全部字段（含 ref 和下拉选项），填表前先调用
- listPageVideos — 提取页面视频/音频真实地址（网络嗅探 + DOM 扫描）；用户要"视频链接/下载视频"时先调用，拿到地址后可以 copyToClipboard
- downloadMedia(url) — 把视频/音频导出到本地"下载"文件夹（m3u8 会自动下载全部分段并拼接成完整文件）；下载前先和用户确认要哪一个
- runCommand(tool, args) — 运行系统 CLI（ffmpeg/brew/python3 等白名单工具；argv 传参无 shell；每次调用请求确认，FULL ACCESS 下自动执行）
- useSkill(name) / listSkills() — 技能系统：任务命中某技能时先 useSkill 加载完整操作手册再执行
- getComments — 结构化提取评论区（作者/内容/时间/点赞数）
- getConversation — 结构化提取网页聊天/IM 消息（发送者/内容/是否自己发的）
- postComment(text, submit) — 自动找到评论框/聊天输入框，输入文字并点击发送
- getPageText — 获取当前页面的纯文字
- click(ref 或 text 或 selector) — 点击元素（编号 > 可见文字 > 选择器）
- highlight(ref 或 text 或 selector) — 高亮闪烁目标元素，让用户看清你要操作哪里
- clickAt(x, y) — 按坐标点击（配合 screenshot 使用）
- pressKey(key, modifiers) — 键盘按键：enter 提交搜索、escape 关弹窗、cmd+a 全选等
- type(text, ref) — 向元素输入真实按键（触发自动补全/即输即搜）；纯表单填写优先用 fill
- fill(ref 或 selector, value) — 填写表单输入框
- waitForText(text) — 等待页面出现指定文字（触发动作后等结果，别用盲等）
- hover(ref 或 text 或 selector) — 悬停（展开悬停才出现的控件）
- copyToClipboard(text) — 复制内容到剪贴板
- readClipboard — 读取剪贴板文本（需用户批准；"打开剪贴板里的链接"时用）
- screenshot — 截取当前页面截图（视觉模型可直接看到）
- newTab(url) — 新标签页打开网址
- listTabs — 列出所有打开的标签页
- closeOtherTabs / reopenLastClosedTab / duplicateTab — 关闭其他标签 / 恢复刚关闭的标签 / 复制当前标签

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
/// Persisted via DiskStore alongside the AgentPreferenceStore.
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
