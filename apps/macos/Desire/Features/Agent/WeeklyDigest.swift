import Foundation

/// 周报（v0.7.22）的**纯逻辑**：把"近 N 天"的确定性数据拼成一段可读回顾。
/// **不经模型**（模板化，零调用成本、结果可解释）；金额刻意不进周报——
/// 逐日桶只有 token/轮数，窗口口径的金额拿不到，塞一个"全时段金额"会撒谎
/// （金额看使用统计页，那里有完整上下文）。
nonisolated enum WeeklyDigest {

    struct Input {
        var days: Int
        /// 窗口内更新过的会话数。
        var conversationCount: Int
        /// 这些会话里的消息总数。
        var messageCount: Int
        /// 窗口内（逐日桶求和）token 与"轮"数。
        var windowTokens: Int
        var windowTurns: Int
        var newFactCount: Int
        var newFactSamples: [String]
        /// 收件箱待办（全量现状：被打断的回合/未回答/互动/失败任务/…）。
        var inboxActionCount: Int
        var inboxByTitle: [(title: String, count: Int)]
        var newSkillNames: [String]
    }

    static func compose(_ input: Input) -> String {
        var lines: [String] = []
        lines.append(String(format: String(localized: "Weekly review — last %lld days"), input.days))
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
        if !input.newSkillNames.isEmpty {
            lines.append("· " + String(format: String(localized: "Skills: %@ new"),
                                       input.newSkillNames.prefix(3).joined(separator: "、")))
        }
        return lines.joined(separator: "\n")
    }
}
