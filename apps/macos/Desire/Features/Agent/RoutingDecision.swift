import Foundation

/// 成本感知路由的**纯决策逻辑**——从 `RoutingProvider` 抽出（它依赖
/// FoundationModels/偏好 store，进不了纯逻辑单测 harness）。
///
/// 路由目标（首条命中生效）：
/// 1. 工具链进行中（锁定或 tools 已提供且有工具流量）→ 具备工具能力的提供方：
///    有云 Key 用云、否则 Ollama、都没有仍报云（让错误可见而非静默降级）。
/// 2. 本地可胜任的纯文本任务（无工具）：关键词命中（总结/翻译/概要），或
///    **成本感知开启**时的"简单短文本"启发式（本轮输入短 + 上下文小）——
///    免费的本地模型先上，云端留给真正需要它的回合。
/// 3. 其余 → 云。
///
/// 本地优先顺序：Foundation Models（系统内置、免费）→ Ollama（自托管、免费）→ 云。
nonisolated enum RoutingDecision {

    enum Target {
        case cloud, foundationModels, ollama
    }

    struct Input {
        var hasToolTraffic: Bool = false
        var toolsOffered: Bool = false
        var lockedToCloud: Bool = false
        var lastUserPrompt: String?
        /// 全部消息 content 的字符总量（上下文规模代理量——本地模型的可用
        /// 窗口远小于云端，上下文大了不往本地塞）。
        var contextChars: Int = 0
        var foundationAvailable: Bool = false
        var ollamaConfigured: Bool = false
        var hasCloudKey: Bool = false
        /// 用户设置的"成本感知路由"开关。
        var costAware: Bool = false
    }

    /// 本地可胜任的输入长度上限（成本感知启发式）：本轮输入与上下文都小，
    /// 才算"简单文本任务"。
    static let simplePromptMaxChars = 240
    static let simpleContextMaxChars = 4_000

    static func decide(_ input: Input) -> Target {
        // Rule 1: 工具链粘滞——进入工具链后必须留在有工具能力的提供方。
        if input.lockedToCloud || (input.toolsOffered && input.hasToolTraffic) {
            return toolCapable(input)
        }

        // Rule 2: 本地可胜任的纯文本任务。
        if !input.toolsOffered, !input.hasToolTraffic,
           let prompt = input.lastUserPrompt,
           isLocalEligible(prompt: prompt, contextChars: input.contextChars, costAware: input.costAware) {
            if input.foundationAvailable { return .foundationModels }
            if input.ollamaConfigured { return .ollama }
            return .cloud
        }

        // Rule 3: 默认云。
        return .cloud
    }

    static func toolCapable(_ input: Input) -> Target {
        if input.hasCloudKey { return .cloud }
        if input.ollamaConfigured { return .ollama }
        // 没有任何工具能力提供方：仍返回云，让 .noAPIKey 错误可见，
        // 而不是静默降级到会无视工具的纯文本模型。
        return .cloud
    }

    /// 关键词命中（保守），或成本感知下的"简单短文本"启发式。
    static func isLocalEligible(prompt: String, contextChars: Int, costAware: Bool) -> Bool {
        if Self.keywords.contains(where: { prompt.lowercased().contains($0) }) { return true }
        guard costAware else { return false }
        return prompt.count <= simplePromptMaxChars && contextChars <= simpleContextMaxChars
    }

    static let keywords = [
        // English
        "summarize", "summary", "tldr", "tl;dr", "recap",
        "translate", "translation",
        // Chinese
        "总结", "摘要", "概括", "翻译", "简述",
    ]
}
