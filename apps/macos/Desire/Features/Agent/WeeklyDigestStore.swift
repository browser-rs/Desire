import Combine
import Foundation
import os

/// 周报投递（v0.7.22）：每周固定（默认周一 09:00）把"近 7 天"的确定性回顾
/// 落进当前会话备注 + routine 档系统通知（过免打扰/预算闸，与通知分级天然
/// 组合）。**纯模板、零模型调用**——与心跳（模型自决）互补：那是"要不要打扰"，
/// 这是"定期给个交代"。
///
/// 调度同心跳模式：自持 60s tick，到点且未投递过才跑；回合进行中推迟到下个
/// tick。上次投递时间是持久化的事实（避免同一天重复投）。
@MainActor
final class WeeklyDigestStore: ObservableObject {
    static let shared = WeeklyDigestStore()

    static let hourChoices = [8, 9, 10, 18, 20]

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "weeklyDigestEnabled") }
    }
    /// 1 = 周日（Calendar 口径），2 = 周一 … 7 = 周六。默认周一。
    @Published var weekday: Int {
        didSet { UserDefaults.standard.set(weekday, forKey: "weeklyDigestWeekday") }
    }
    @Published var hour: Int {
        didSet { UserDefaults.standard.set(hour, forKey: "weeklyDigestHour") }
    }
    @Published private(set) var lastDeliveredAt: Date?
    @Published private(set) var lastDigestText: String?

    private var timer: Timer?
    private static let lastDeliveredKey = "weeklyDigestLastDelivered"
    private static let lastTextKey = "weeklyDigestLastText"

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "weeklyDigestEnabled") as? Bool ?? false
        let storedWeekday = UserDefaults.standard.object(forKey: "weeklyDigestWeekday") as? Int ?? 2
        weekday = (1...7).contains(storedWeekday) ? storedWeekday : 2
        let storedHour = UserDefaults.standard.object(forKey: "weeklyDigestHour") as? Int ?? 9
        hour = Self.hourChoices.contains(storedHour) ? storedHour : 9
        lastDeliveredAt = UserDefaults.standard.object(forKey: Self.lastDeliveredKey) as? Date
        lastDigestText = UserDefaults.standard.string(forKey: Self.lastTextKey)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.deliverIfDue()
            }
        }
    }

    // MARK: - 调度

    /// 本周期最近一次"应投递"时刻（本周的 weekday@hour；今天未到点则退回上周）。
    func lastScheduledFire(now: Date = Date()) -> Date? {
        var calendar = Calendar.current
        calendar.firstWeekday = 1
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        guard let thisWeek = calendar.nextDate(after: now, matching: components,
                                               matchingPolicy: .nextTime, direction: .backward) else {
            return nil
        }
        return thisWeek
    }

    func isDue(now: Date = Date()) -> Bool {
        guard isEnabled, let fire = lastScheduledFire(now: now) else { return false }
        guard let last = lastDeliveredAt else { return true }
        return last < fire
    }

    func deliverIfDue() {
        guard isDue() else { return }
        // 忙时推迟：不打断进行中的回合，下个 tick 再看。
        if AgentScheduler.shared.deliveryTarget?.isProcessing == true { return }
        Task { await runNow() }
    }

    /// 立即生成并投递（设置页按钮 / 桥 / E2E；绕过到点判断）。
    @discardableResult
    func runNow(days: Int = 7) async -> String {
        let text = Self.buildText(days: days)
        lastDeliveredAt = Date()
        lastDigestText = text
        UserDefaults.standard.set(lastDeliveredAt, forKey: Self.lastDeliveredKey)
        UserDefaults.standard.set(text, forKey: Self.lastTextKey)
        AgentScheduler.shared.deliveryTarget?.appendExternalNote(text)
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Weekly review ready"),
            body: String(localized: "The last 7 days are summarized in the Agent panel — conversations, usage, memory and inbox at a glance."),
            tier: .routine)
        return text
    }

    // MARK: - 数据（确定性派生，全部来自既有 store）

    static func buildInput(days: Int = 7, now: Date = Date()) -> WeeklyDigest.Input {
        let start = now.addingTimeInterval(TimeInterval(-days * 86_400))
        let app = AppState.live

        let conversations = app?.conversationStore.conversations ?? []
        let windowConversations = conversations.filter { $0.updatedAt >= start }
        let messageCount = windowConversations.reduce(0) { $0 + $1.messages.count }

        // 窗口用量：逐日桶求和（窗口精确；金额不进周报，见 WeeklyDigest 注释）。
        var calendar = Calendar.current
        calendar.firstWeekday = 1
        let stats = UsageStats.derive(from: conversations,
                                      price: app?.aiPreference.usagePrice(for:) ?? { _ in nil })
        let windowDays = stats.days.filter { $0.id >= start }
        let windowTokens = windowDays.reduce(0) { $0 + $1.tokens }
        let windowTurns = windowDays.reduce(0) { $0 + $1.turns }

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

        let newSkills = SkillStore.shared.skills.filter { skill in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: skill.url.path),
                  let modified = attrs[.modificationDate] as? Date else { return false }
            return modified >= start
        }.map(\.name)

        return WeeklyDigest.Input(
            days: days,
            conversationCount: windowConversations.count,
            messageCount: messageCount,
            windowTokens: windowTokens,
            windowTurns: windowTurns,
            newFactCount: newFacts.count,
            newFactSamples: samples,
            inboxActionCount: inboxCount,
            inboxByTitle: inboxByTitle,
            newSkillNames: newSkills)
    }

    static func buildText(days: Int = 7) -> String {
        WeeklyDigest.compose(buildInput(days: days))
    }
}
