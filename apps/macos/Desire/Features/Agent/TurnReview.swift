import Foundation

/// 「轨迹复盘卡」的**纯逻辑**（v0.7.22；Foundation-only 进 harness）：
/// 从轨迹回合里抽失败/慢模式 → 可解释的**输出规则草稿**（模板化，不经模型）。
/// 轨迹页与桥 `/agent/rule-draft` 共用——口径只有一处。
nonisolated enum TurnReview {

    struct StepFact: Equatable {
        let action: String
        let denied: Bool
        let threwError: Bool
        let durationMs: Double?
    }

    struct RuleDraft: Equatable {
        enum Kind: String, Equatable {
            case denied, errored, slow
        }
        let kind: Kind
        let tool: String
        let avgMs: Double?
    }

    /// 从 AgentTrace 的回合字典抽步事实（字段：action / denied / threwError / ms）。
    static func stepFacts(fromTurn turn: [String: Any]) -> [StepFact] {
        let steps = turn["steps"] as? [[String: Any]] ?? []
        return steps.compactMap { step in
            guard let action = step["action"] as? String, !action.isEmpty else { return nil }
            return StepFact(action: action,
                            denied: step["denied"] as? Bool ?? false,
                            threwError: step["threwError"] as? Bool ?? false,
                            durationMs: step["ms"] as? Double)
        }
    }

    /// 失败/慢模式 → 规则草稿：被拒 → 出错 → 慢（各按工具去重，封顶 3 条）。
    /// 无失败且无慢工具返回空——不硬凑规则。
    static func drafts(from steps: [StepFact], slowThresholdMs: Double = 8_000) -> [RuleDraft] {
        var drafts: [RuleDraft] = []
        var seen: Set<String> = []

        func add(_ kind: RuleDraft.Kind, _ tool: String, avgMs: Double? = nil) {
            let key = "\(kind.rawValue)|\(tool)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            drafts.append(RuleDraft(kind: kind, tool: tool, avgMs: avgMs))
        }

        for step in steps where step.denied {
            add(.denied, step.action)
        }
        for step in steps where step.threwError {
            add(.errored, step.action)
        }
        // 慢工具：按工具算平均（≥1 次调用且平均超阈值。
        var totals: [String: (count: Int, ms: Double)] = [:]
        for step in steps {
            guard let ms = step.durationMs, ms > 0 else { continue }
            let entry = totals[step.action] ?? (0, 0)
            totals[step.action] = (entry.count + 1, entry.ms + ms)
        }
        for (tool, entry) in totals
            .sorted(by: { $0.value.ms / Double($0.value.count) > $1.value.ms / Double($1.value.count) }) {
            let avg = entry.ms / Double(entry.count)
            if avg >= slowThresholdMs {
                add(.slow, tool, avgMs: (avg * 10).rounded() / 10)
            }
        }
        return Array(drafts.prefix(3))
    }

    /// 草稿 → 规则文本（本地化模板；写入用户设置的"输出规则"后进 <output_rules> 层）。
    static func ruleText(for draft: RuleDraft) -> String {
        switch draft.kind {
        case .denied:
            return String(format: String(localized: "%@ was denied by the user before — ask for confirmation first instead of calling it directly."),
                          draft.tool)
        case .errored:
            return String(format: String(localized: "%@ returned an error before — validate its result (the Error: prefix) before continuing, and switch approach instead of blind retries."),
                          draft.tool)
        case .slow:
            let seconds = String(format: "%.1fs", (draft.avgMs ?? 0) / 1000)
            return String(format: String(localized: "%@ took about %@ on average — announce an expected duration before slow steps."),
                          draft.tool, seconds)
        }
    }
}
