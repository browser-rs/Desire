import Foundation

/// 每日简报（v0.7.25）的**纯逻辑**：把"今天"的确定性数据拼成一段可读简报。
/// **不经模型**（模板化，零调用成本、结果可解释）；金额不进简报（同周报：
/// 逐日桶只有 token/轮数，塞全时段金额会撒谎）。
nonisolated enum DailyBrief {
    struct Input {
        /// 今天更新过的会话数 + 消息总数。
        var conversationCount: Int
        var messageCount: Int
        /// 今天的 token 与轮数（逐日桶求和）。
        var windowTokens: Int
        var windowTurns: Int
        var newFactCount: Int
        var newFactSamples: [String]
        /// 收件箱待办（全量现状）。
        var inboxActionCount: Int
        var inboxByTitle: [(title: String, count: Int)]
    }

    static func compose(_ input: Input, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var lines: [String] = []
        lines.append("今日简报 — \(formatter.string(from: date))")
        lines.append("· " + String(format: String(localized: "Conversations: %lld active · %lld messages"),
                                     input.conversationCount, input.messageCount))
        lines.append("· " + String(format: String(localized: "Usage: %@ tokens over %lld turns"),
                                     AgentUsage.formatTokens(input.windowTokens), input.windowTurns))
        if input.newFactCount > 0 {
            var factLine = String(format: String(localized: "Memory: %lld new"), input.newFactCount)
            if !input.newFactSamples.isEmpty {
                factLine += "：" + input.newFactSamples.joined(separator: "；")
            }
            lines.append("· " + factLine)
        }
        if input.inboxActionCount > 0 {
            let detail = input.inboxByTitle.prefix(3)
                .map { "\($0.title) \($0.count)" }
                .joined(separator: " · ")
            var inboxLine = String(format: String(localized: "Inbox: %lld item(s) waiting"), input.inboxActionCount)
            if !detail.isEmpty { inboxLine += "（\(detail)）" }
            lines.append("· " + inboxLine)
        }
        return lines.joined(separator: "\n")
    }
}
