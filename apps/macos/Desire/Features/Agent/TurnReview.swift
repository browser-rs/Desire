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
        /// 调用参数（v0.7.27 重试计数用；旧轨迹没有 → nil）。
        var args: String? = nil
    }

    struct TimeSlice: Equatable {
        let tool: String
        let ms: Double
        /// 占本回合已计时步骤总耗时的比例（0…1）。
        let share: Double
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
                            durationMs: step["ms"] as? Double,
                            args: step["args"] as? String)
        }
    }

    /// 按工具聚合的耗时分布（v0.7.27）：只统计有耗时的步骤，按总耗时降序；
    /// 总耗时 ≤ 0 → 空（旧轨迹没有耗时，不硬凑）。UI 画比例条。
    static func timeDistribution(from steps: [StepFact]) -> [TimeSlice] {
        let timed = steps.compactMap { step -> (String, Double)? in
            guard let ms = step.durationMs, ms > 0 else { return nil }
            return (step.action, ms)
        }
        let total = timed.reduce(0.0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        var totals: [String: Double] = [:]
        for (tool, ms) in timed { totals[tool, default: 0] += ms }
        return totals.map { TimeSlice(tool: $0.key, ms: $0.value, share: $0.value / total) }
            .sorted { $0.ms > $1.ms }
    }

    /// 同参数失败重试次数（v0.7.27）：把 (工具, 参数) 完全相同的步骤归组，
    /// **该组至少失败过一次**时，多出来的次数就是重试（3 次里 2 次是重试）。
    /// 参数缺失的旧轨迹按"同工具"归组（更保守：仍能看出重复调用）。
    static func retryCount(from steps: [StepFact]) -> Int {
        var groups: [String: (count: Int, failed: Bool)] = [:]
        for step in steps {
            let key = step.action + "|" + (step.args ?? "")
            var entry = groups[key] ?? (0, false)
            entry.count += 1
            entry.failed = entry.failed || step.denied || step.threwError
            groups[key] = entry
        }
        return groups.values
            .filter { $0.failed && $0.count >= 2 }
            .reduce(0) { $0 + ($1.count - 1) }
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
