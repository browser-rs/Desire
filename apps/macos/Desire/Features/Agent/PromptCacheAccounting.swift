import Foundation

/// **提示词缓存的用量口径**（v0.8.80，Foundation-only 进 harness）。
///
/// 三家服务都自动缓存前缀，但字段各不相同：
/// - OpenAI：`usage.prompt_tokens_details.cached_tokens`
/// - DeepSeek（及部分兼容网关）：`usage.prompt_cache_hit_tokens`
/// - Anthropic：`usage.cache_read_input_tokens`（写入侧另有
///   `cache_creation_input_tokens`，不计入"命中"）
///
/// 命中率 = 缓存命中的输入 token ÷ 输入 token 总数。没有上报的服务按 0 处理
/// （**不估算**——算错了会让人以为省钱）。
nonisolated enum PromptCacheAccounting {
    static func cachedTokens(openAIUsage usage: [String: Any]) -> Int {
        if let details = usage["prompt_tokens_details"] as? [String: Any],
           let cached = details["cached_tokens"] as? Int, cached > 0 {
            return cached
        }
        if let hit = usage["prompt_cache_hit_tokens"] as? Int, hit > 0 { return hit }
        // 部分网关直接把 cached_tokens 放在 usage 顶层。
        if let cached = usage["cached_tokens"] as? Int, cached > 0 { return cached }
        return 0
    }

    static func cachedTokens(anthropicUsage usage: [String: Any]) -> Int {
        max(0, usage["cache_read_input_tokens"] as? Int ?? 0)
    }

    /// Anthropic 提示词缓存的模型门槛：3.5 Sonnet v2 之后、3.7 与 4.x。
    /// （3.5 Haiku 不支持缓存，显式排除。）
    static func supportsPromptCaching(model: String) -> Bool {
        let id = model.lowercased()
        if id.contains("claude-3-5-haiku") { return false }
        return id.contains("claude-3-5-sonnet") || id.contains("claude-3-7")
            || id.contains("claude-sonnet-4") || id.contains("claude-opus-4")
            || id.contains("claude-haiku-4") || id.contains("claude-4")
    }

    static func hitRate(cached: Int, prompt: Int) -> Double {
        guard prompt > 0, cached > 0 else { return 0 }
        return min(1, Double(cached) / Double(prompt))
    }
}
