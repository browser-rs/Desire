import Combine
import Foundation

/// 每日简报的投递（v0.7.25）：数据全来自既有 store（确定性派生），投递 =
/// 会话备注 + routine 通知；可选上板（UserDefaults `agent.dailyBrief.toBoard`）。
/// 触发面：内置定时任务（builtin=dailyBrief）/ 桥 `POST /agent/daily-brief`。
@MainActor
enum DailyBriefService {
    static let toBoardKey = "agent.dailyBrief.toBoard"

    @discardableResult
    static func runNow(now: Date = Date(), toBoard: Bool? = nil) -> String {
        let text = DailyBrief.compose(buildInput(now: now), date: now)
        AgentScheduler.shared.deliveryTarget?.appendExternalNote(text)
        let summary = text.components(separatedBy: "\n").dropFirst().first ?? text
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Daily brief ready"),
            body: String(summary.prefix(160)),
            tier: .routine)
        let wantBoard = toBoard ?? UserDefaults.standard.bool(forKey: toBoardKey)
        if wantBoard {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let block = WhiteboardBlock(
                type: WhiteboardBlock.Kind.note,
                title: "简报 \(formatter.string(from: now))",
                content: "## " + text)
            WhiteboardStore.shared.append(
                [block], title: nil,
                conversationID: AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString)
        }
        return text
    }

    static func buildInput(now: Date = Date()) -> DailyBrief.Input {
        let start = Calendar.current.startOfDay(for: now)
        let app = AppState.live

        let conversations = app?.conversationStore.conversations ?? []
        let todayConversations = conversations.filter { $0.updatedAt >= start }
        let messageCount = todayConversations.reduce(0) { $0 + $1.messages.count }

        let stats = UsageStats.derive(from: conversations,
                                      price: app?.aiPreference.usagePrice(for:) ?? { _ in nil })
        let todayDays = stats.days.filter { $0.id >= start }
        let windowTokens = todayDays.reduce(0) { $0 + $1.tokens }
        let windowTurns = todayDays.reduce(0) { $0 + $1.turns }

        let memory = AgentMemoryStore.shared
        let newFacts = memory.factsSnapshot.filter { $0.createdAt >= start }
        let samples = newFacts.prefix(3).map { String($0.content.prefix(40)) }

        let dismissals = AgentInboxDismissalStore.shared
        dismissals.purgeExpired()
        let inboxSections = AgentInbox.build(AgentInboxCollector.diskInputs(),
                                             hidden: { dismissals.isHidden($0) })
            .filter { !$0.items.isEmpty }
        let inboxCount = AgentInbox.actionCount(inboxSections)
        let inboxByTitle = inboxSections.map { ($0.title, $0.items.count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }

        return DailyBrief.Input(
            conversationCount: todayConversations.count,
            messageCount: messageCount,
            windowTokens: windowTokens,
            windowTurns: windowTurns,
            newFactCount: newFacts.count,
            newFactSamples: samples,
            inboxActionCount: inboxCount,
            inboxByTitle: inboxByTitle)
    }
}
