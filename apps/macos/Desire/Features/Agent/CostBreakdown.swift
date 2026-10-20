import Foundation

/// 本对话成本明细（v0.7.26）：按 **模型 × 类型** 拆开 token 与金额——主回合、
/// 子代理（工具消息上的用量）、旁路（标题/记忆/自评/守护/划词卡…逐笔）。
/// 纯逻辑（Foundation-only，进 harness）；总额仍走 `AgentUsage.of` **单一口径**，
/// 这里只负责拆组与标注未定价。
nonisolated enum CostBreakdown {
    struct Group: Equatable, Identifiable {
        var id: String
        /// main | subagent | bypass
        var category: String
        /// 旁路种类（title/facts/summary/critique/guard/selectionAssist…）
        var kind: String?
        var model: String?
        var promptTokens: Int
        var completionTokens: Int
        /// nil = 该组含未定价模型（不显示 $0）。
        var usd: Double?

        var totalTokens: Int { promptTokens + completionTokens }
    }

    struct Result: Equatable {
        var groups: [Group]
        /// 与面板/轨迹/统计同一口径的合计（含 hasUnpriced / ≥ 规则）。
        var usage: AgentUsage
    }

    static func derive(_ messages: [AgentMessage], price: (String?) -> ModelPrice?) -> Result {
        struct Acc { var prompt = 0; var completion = 0; var usd: Double? = 0; var unpriced = false }
        var accs: [String: Acc] = [:]
        var meta: [String: (category: String, kind: String?, model: String?)] = [:]

        func add(category: String, kind: String?, model: String?, prompt: Int, completion: Int) {
            guard prompt > 0 || completion > 0 else { return }
            let key = "\(category)|\(kind ?? "")|\(model ?? "")"
            var acc = accs[key] ?? Acc()
            acc.prompt += prompt
            acc.completion += completion
            if let known = price(model),
               let cost = known.cost(promptTokens: prompt, completionTokens: completion) {
                acc.usd = (acc.usd ?? 0) + cost
            } else {
                acc.unpriced = true
                acc.usd = nil
            }
            accs[key] = acc
            meta[key] = (category, kind, model)
        }

        for message in messages {
            let bypass = message.bypassUsage ?? []
            let bypassPrompt = bypass.reduce(0) { $0 + $1.promptTokens }
            let bypassCompletion = bypass.reduce(0) { $0 + $1.completionTokens }
            let mainPrompt = max(0, (message.promptTokens ?? 0) - bypassPrompt)
            let mainCompletion = max(0, (message.completionTokens ?? 0) - bypassCompletion)
            let category = message.role == .tool ? "subagent" : "main"
            add(category: category, kind: message.role == .tool ? (message.toolName ?? "tool") : nil,
                model: message.model, prompt: mainPrompt, completion: mainCompletion)
            for record in bypass {
                add(category: "bypass", kind: record.kind, model: record.model,
                    prompt: record.promptTokens, completion: record.completionTokens)
            }
        }

        let order = ["main": 0, "subagent": 1, "bypass": 2]
        let groups = accs.map { key, acc -> Group in
            let m = meta[key]!
            return Group(id: key, category: m.category, kind: m.kind, model: m.model,
                         promptTokens: acc.prompt, completionTokens: acc.completion,
                         usd: acc.unpriced ? nil : acc.usd)
        }.sorted { a, b in
            let oa = order[a.category] ?? 9
            let ob = order[b.category] ?? 9
            if oa != ob { return oa < ob }
            return a.totalTokens > b.totalTokens
        }
        return Result(groups: groups, usage: AgentUsage.of(messages, price: price))
    }
}
