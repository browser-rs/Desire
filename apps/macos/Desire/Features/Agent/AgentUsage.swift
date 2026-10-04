import Foundation

/// 一个回合、一次会话（或任意一组消息）的 token 用量与折算成本。
///
/// `usd == nil` 是**有意义的状态**：有 token 但没有单价 → 调用方不显示金额
/// （显示 $0.0000 会被读成"免费"）。混着已定价与未定价模型时同样为 nil，
/// 因为那时总额只是下界，标出来会误导。
struct AgentUsage: Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    /// 有定价的那些调用折算出的美元金额；只要有一个调用无法定价就是 nil。
    var usd: Double?
    /// 是否有调用因为缺单价而没算进去（提示"金额是下界/未知"时用）。
    var hasUnpriced = false

    var totalTokens: Int { promptTokens + completionTokens }
    var isEmpty: Bool { totalTokens == 0 }

    /// 从消息里汇总。**按每条消息自己记下的模型**查价——routing/中途换模型的
    /// 会话因此也算得对；消息没记模型（本功能之前落盘的旧会话）就交给调用方
    /// 决定的兜底模型。
    static func of(_ messages: [AgentMessage], price: (String?) -> ModelPrice?) -> AgentUsage {
        var usage = AgentUsage()
        for message in messages {
            let prompt = message.promptTokens ?? 0
            let completion = message.completionTokens ?? 0
            guard prompt > 0 || completion > 0 else { continue }
            usage.promptTokens += prompt
            usage.completionTokens += completion
            if let known = price(message.model) {
                if let cost = known.cost(promptTokens: prompt, completionTokens: completion) {
                    usage.usd = (usage.usd ?? 0) + cost
                    continue
                }
            }
            usage.hasUnpriced = true
        }
        // 有算不进去的调用 → 金额不是总额，别冒充总额。
        if usage.hasUnpriced { usage.usd = nil }
        return usage
    }

    /// 面板/轨迹里的金额写法：小额给 4 位小数（一次轻问答常常 $0.0004），
    /// 大额才收敛到分。**比 4 位小数还小的非零值写成 `< $0.0001`**——四舍五入成
    /// `$0.0000` 会被读成"不花钱"，那是另一种谎。
    static func formatUSD(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value >= 1 { return String(format: "$%.2f", value) }
        if value >= 0.01 { return String(format: "$%.3f", value) }
        if value >= 0.0001 { return String(format: "$%.4f", value) }
        return "< $0.0001"
    }

    var formattedUSD: String? {
        usd.map { Self.formatUSD($0) }
    }

    /// token 数的紧凑写法（1.2k / 12k / 123k）。
    static func formatTokens(_ count: Int) -> String {
        if count >= 100_000 { return String(format: "%.0fk", Double(count) / 1000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1000) }
        return "\(count)"
    }
}
