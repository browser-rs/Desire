import Foundation

/// 定时任务失败分类（v0.8.19 替人干活 11）：RunRecord.error 启发式归档
/// ——通知里带类别与"该看哪里"的指引。Foundation-only，进 tests/run.sh。
nonisolated enum TaskFailureClassify {

    enum Category: String {
        case network      // 网络/连接/超时（瞬态——重试有意义）
        case approval     // 审批被拒/等待（人在环）
        case model        // 模型侧（限流/余额/服务错误）
        case context      // 上下文超限（压缩预算问题）
        case toolError    // 工具执行失败（看轨迹）
        case other

        var hint: String {
            switch self {
            case .network: return String(localized: "Transient — the automatic retry may succeed")
            case .approval: return String(localized: "Check approval settings or run it in the foreground")
            case .model: return String(localized: "Check the model service / quota / balance")
            case .context: return String(localized: "Compaction budget — shorten the prompt or raise the budget")
            case .toolError: return String(localized: "Open the trace page for the failing step")
            case .other: return String(localized: "Open the trace page for details")
            }
        }
    }

    nonisolated static func classify(_ error: String?) -> Category {
        let e = (error ?? "").lowercased()
        guard !e.isEmpty else { return .other }
        let network = ["timed out", "timeout", "connection", "network", "offline",
                       "dns", "ssl", "tls", "host unreachable", "挂起", "超时"]
        if network.contains(where: { e.contains($0) }) { return .network }
        let approval = ["approval", "denied", "declined", "rejected by user", "not allowed",
                        "审批", "拒绝"]
        if approval.contains(where: { e.contains($0) }) { return .approval }
        let context = ["context length", "context window", "too many tokens", "压缩预算",
                       "上下文"]
        if context.contains(where: { e.contains($0) }) { return .context }
        let model = ["rate limit", "429", "quota", "insufficient", "balance", "billing",
                     "503", "overloaded", "invalid api key", "unauthorized", "401",
                     "model not found", "限流", "余额"]
        if model.contains(where: { e.contains($0) }) { return .model }
        if e.contains("error:") || e.contains("failed") || e.contains("exception") {
            return .toolError
        }
        return .other
    }

    /// 通知正文的一行：`类别 · 指引`。
    nonisolated static func diagnosisLine(_ error: String?) -> String {
        let category = classify(error)
        return "• \(category.rawValue) — \(category.hint)"
    }
}
