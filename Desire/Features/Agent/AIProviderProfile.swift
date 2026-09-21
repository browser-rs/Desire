import Foundation

/// 一个模型服务档案：端点 + 模型 + **自己的凭据**。
///
/// 这是"自定义模型配置"的一等公民。此前配置散在三处：`cloudProviderID`
/// （决定用哪把 Keychain Key）、全局单例 `endpoint`/`model`、以及只有
/// `name/url/model` 的 `savedEndpoints`——于是自定义端点只能串用某个预设的
/// Key，也没法给不同网关配不同请求头。现在内置的 4 个预设（OpenAI /
/// DeepSeek / 智谱 / OpenCode Go）就是 `isBuiltin` 的档案，用户加的每个网关
/// 也是档案，各自独立。
struct AIProviderProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// 完整的 chat-completions URL（缺 `/chat/completions` 时请求前会补）。
    var endpoint: String
    var model: String
    /// 候选模型：预设 + 用户手输记下的 + 从 `/models` 拉回的。
    var modelList: [String]
    /// 额外请求头（自定义网关常见：租户 id、路由键…）。
    /// `Authorization` / `Content-Type` 由请求构造方掌管，这里不参与。
    var headers: [String: String]
    /// 内置预设：可改、可复制，不可删。
    var isBuiltin: Bool
    var createdAt: Date
    /// Keychain 账号。内置档案沿用 `ai-key-<providerID>`（升级后老 Key 直接
    /// 可用），自定义档案按 id 隔离（`ai-key-profile-<uuid>`）。
    var keychainAccount: String

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: String,
        model: String = "",
        modelList: [String] = [],
        headers: [String: String] = [:],
        isBuiltin: Bool = false,
        createdAt: Date = Date(),
        keychainAccount: String? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.modelList = modelList
        self.headers = headers
        self.isBuiltin = isBuiltin
        self.createdAt = createdAt
        self.keychainAccount = keychainAccount ?? "ai-key-profile-\(id.uuidString)"
    }

    /// 端点主机（设置页副标题里显示，比整条 URL 好读）。
    var host: String {
        guard let host = URL(string: endpoint)?.host, !host.isEmpty else { return endpoint }
        return host
    }

    /// 内置预设。`providerID` 同时是老版本的 Keychain 账号后缀——保持它，
    /// 升级后用户原来的 Key 依然在。
    static func builtins(endpointOverride: String? = nil, modelOverride: String? = nil, providerID: String = "openai") -> [AIProviderProfile] {
        var list: [AIProviderProfile] = [
            AIProviderProfile(
                name: "OpenAI",
                endpoint: "https://api.openai.com/v1/chat/completions",
                model: "gpt-4o",
                modelList: ["gpt-4o", "gpt-4o-mini", "o3-mini", "gpt-4-turbo", "o1-preview"],
                isBuiltin: true,
                keychainAccount: "ai-key-openai"
            ),
            AIProviderProfile(
                name: "DeepSeek",
                endpoint: "https://api.deepseek.com/v1/chat/completions",
                model: "deepseek-chat",
                modelList: ["deepseek-chat", "deepseek-coder", "deepseek-reasoner"],
                isBuiltin: true,
                keychainAccount: "ai-key-deepseek"
            ),
            AIProviderProfile(
                name: "Zhipu GLM",
                endpoint: "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions",
                model: "glm-4-plus",
                modelList: ["glm-4-plus", "glm-4-flash", "glm-4-long", "glm-4v-plus", "glm-4-air"],
                isBuiltin: true,
                keychainAccount: "ai-key-zhipu"
            ),
            AIProviderProfile(
                name: "OpenCode Go",
                endpoint: "https://opencode.ai/zen/go/v1/chat/completions",
                model: "claude-sonnet-4-20250514",
                modelList: ["glm-4-plus", "deepseek-chat", "claude-3-5-sonnet"],
                isBuiltin: true,
                keychainAccount: "ai-key-opencode-go"
            ),
        ]
        // 老版本把"当前端点/模型"存在全局字段里：如果它与某个内置预设都对不上，
        // 就当成一个自定义档案带过来，别让用户的配置消失。
        let endpoint = (endpointOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty, !list.contains(where: { $0.endpoint == endpoint }) {
            list.append(AIProviderProfile(
                name: "Imported (\(providerID))",
                endpoint: endpoint,
                model: modelOverride ?? "",
                isBuiltin: false,
                keychainAccount: "ai-key-\(providerID)"
            ))
        }
        return list
    }
}
