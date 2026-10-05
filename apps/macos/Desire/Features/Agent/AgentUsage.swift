import Foundation

/// 一个回合、一次会话（或任意一组消息）的 token 用量与折算成本。
///
/// `usd == nil` 是**有意义的状态**：有 token 但没有单价 → 调用方不显示金额
/// （显示 $0.0000 会被读成"免费"）。混着已定价与未定价模型时同样为 nil，
/// 因为那时总额只是下界，标出来会误导。
struct AgentUsage: Equatable {
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    /// 其中旁路调用（标题/记忆整理/自评）的部分——`promptTokens`/`completionTokens`
    /// 是**含旁路的总量**，主回合 = 总量 − 旁路。旧会话没有旁路明细，旁路为 0。
    var bypassTokens: Int = 0
    /// 有定价的那些调用折算出的美元金额；只要有一个调用无法定价就是 nil。
    var usd: Double?
    /// 是否有调用因为缺单价而没算进去（提示"金额是下界/未知"时用）。
    var hasUnpriced = false

    var totalTokens: Int { promptTokens + completionTokens }
    var isEmpty: Bool { totalTokens == 0 }

    /// 从消息里汇总。**按每段用量自己记下的模型**查价——routing/中途换模型的
    /// 会话因此也算得对：主回合部分按消息的模型，旁路逐笔按各笔自己的模型
    /// （成本路由后旁路跑的模型 ≠ 主模型）。消息没记模型（本功能之前落盘的
    /// 旧会话）就交给调用方决定的兜底模型。
    static func of(_ messages: [AgentMessage], price: (String?) -> ModelPrice?) -> AgentUsage {
        var usage = AgentUsage()
        // 一段用量按某模型查价入账；查不到单价就记为"有算不进去的"。
        func add(_ prompt: Int, _ completion: Int, model: String?) {
            guard prompt > 0 || completion > 0 else { return }
            usage.promptTokens += prompt
            usage.completionTokens += completion
            if let known = price(model), let cost = known.cost(promptTokens: prompt, completionTokens: completion) {
                usage.usd = (usage.usd ?? 0) + cost
            } else {
                usage.hasUnpriced = true
            }
        }
        for message in messages {
            let bypass = message.bypassUsage ?? []
            let bypassPrompt = bypass.reduce(0) { $0 + $1.promptTokens }
            let bypassCompletion = bypass.reduce(0) { $0 + $1.completionTokens }
            // 主回合 = 消息总量 − 旁路逐笔（钳到 0：只防历史数据写坏，正常记账两者恰好相等）。
            add(max(0, (message.promptTokens ?? 0) - bypassPrompt),
                max(0, (message.completionTokens ?? 0) - bypassCompletion),
                model: message.model)
            for record in bypass {
                add(record.promptTokens, record.completionTokens, model: record.model)
                usage.bypassTokens += record.promptTokens + record.completionTokens
            }
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
