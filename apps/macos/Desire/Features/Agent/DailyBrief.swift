import Foundation

/// 每日简报（v0.7.25）的**纯逻辑**：把"今天"的确定性数据拼成一段可读简报。
/// **不经模型**（模板化，零调用成本、结果可解释）；金额不进简报（同周报：
/// 逐日桶只有 token/轮数，塞全时段金额会撒谎）。
nonisolated enum DailyBrief {
    /// 一条进行中战役的进度（标题 + 已完成/总数；Runbook 优先，没 Runbook
    /// 时用已发/总帖子数）。
    struct CampaignLine: Equatable {
        var title: String
        var done: Int
        var total: Int
    }

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
        // 运营段（v0.8.3）：默认 0/空 = 不显示，旧调用点与空工作台保持原样。
        /// 今天到期 / 已逾期的草稿与 Runbook 步骤。
        var opsDueToday: Int = 0
        var opsOverdue: Int = 0
        /// 待回复互动 / 其中超过 72h。
        var opsPendingReplies: Int = 0
        var opsOverdueReplies: Int = 0
        var opsCampaigns: [CampaignLine] = []
        /// 已启用运营适配包的渠道 / 总渠道。
        var opsAdaptersEnabled: Int = 0
        var opsChannels: Int = 0
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
        // 运营段（v0.8.3）：只在有数据时出现，不把空工作台写成"0 件事"。
        if input.opsDueToday > 0 || input.opsOverdue > 0 {
            lines.append("· " + String(format: String(localized: "Operations: %lld due today · %lld overdue"),
                                         input.opsDueToday, input.opsOverdue))
        }
        if input.opsPendingReplies > 0 {
            lines.append("· " + String(format: String(localized: "Replies waiting: %lld (%lld overdue)"),
                                         input.opsPendingReplies, input.opsOverdueReplies))
        }
        if !input.opsCampaigns.isEmpty {
            let detail = input.opsCampaigns.prefix(3)
                .map { "\($0.title) \($0.done)/\($0.total)" }
                .joined(separator: " · ")
            lines.append("· " + String(format: String(localized: "Campaigns: %@"), detail))
        }
        if input.opsChannels > 0 {
            lines.append("· " + String(format: String(localized: "DPP ops adapters: %lld/%lld channels ready"),
                                         input.opsAdaptersEnabled, input.opsChannels))
        }
        return lines.joined(separator: "\n")
    }
}
