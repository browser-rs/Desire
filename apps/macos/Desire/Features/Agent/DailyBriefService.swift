import Combine
import Foundation

/// 每日简报的投递（v0.7.25）：数据全来自既有 store（确定性派生），投递 =
/// 会话备注 + routine 通知；可选上板（UserDefaults `agent.dailyBrief.toBoard`）。
/// 触发面：内置定时任务（builtin=dailyBrief）/ 桥 `POST /agent/daily-brief`。
@MainActor
enum DailyBriefService {
    static let toBoardKey = "agent.dailyBrief.toBoard"

    /// 简报产物（v0.8.20）：workspace `brief-<yyyy-MM-dd>.md`，入账最近文件。
    @discardableResult
    static func productize(_ text: String, now: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = AgentWorkspace.shared.directory
            .appendingPathComponent("brief-\(formatter.string(from: now)).md")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            RecentLocalFiles.record(url: url)
            return url
        } catch {
            return nil
        }
    }

    /// 最近 7 份简报（Remote briefs 帧用；文件名排序即新在前）。
    static func recentBriefs(limit: Int = 7) -> [(date: String, text: String, url: URL)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: AgentWorkspace.shared.directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix("brief-") && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                return (String(name.dropFirst("brief-".count)), text, url)
            }
    }

    static func runNow(now: Date = Date(), toBoard: Bool? = nil) -> String {
        let text = DailyBrief.compose(buildInput(now: now), date: now)
        AgentScheduler.shared.deliveryTarget?.appendExternalNote(text)
        // 产物化（v0.8.20 融合 13）：落 workspace brief-<date>.md 入账，
        // Remote 端 briefs 帧随之可见。
        productize(text, now: now)
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

        // 运营段（v0.8.3）：日历今日/逾期 + 回复台 + 进行中战役 + DPP 适配就绪。
        let promo = PromotionStore.shared
        let calendarEntries = PromotionCalendar.entries(posts: promo.posts,
                                                         campaigns: promo.campaigns,
                                                         now: now)
        let queue = PromotionCalendar.todayQueue(calendarEntries, now: now)
        let dueToday = queue.filter { !$0.overdue }.count
        let overdue = queue.filter(\.overdue).count
        let replySummary = PromotionReplyDesk.summary(interactions: promo.interactions, now: now)
        let campaignLines: [DailyBrief.CampaignLine] = promo.campaigns
            .filter { $0.status.isOpen }
            .compactMap { campaign -> DailyBrief.CampaignLine? in
                let linked = promo.posts(inCampaign: campaign.id)
                if let runbook = campaign.runbook, !runbook.isEmpty {
                    let progress = PromotionRunbook.progress(steps: runbook,
                                                              campaignID: campaign.id,
                                                              posts: linked)
                    return DailyBrief.CampaignLine(title: campaign.title,
                                                   done: progress.done,
                                                   total: progress.total)
                }
                guard !linked.isEmpty else { return nil }
                return DailyBrief.CampaignLine(
                    title: campaign.title,
                    done: linked.filter { $0.status == .published }.count,
                    total: linked.count)
            }
        let channels = PromotionChannel.presets.filter(\.isEnabled)
        let adaptersEnabled = channels.filter { channel in
            guard let host = channel.composerURL.flatMap(URL.init)?.host else { return false }
            return DPPAdapterStore.shared.adapters.contains {
                $0.matchesHost(host) && DPPAdapterStore.shared.isEnabled($0)
            }
        }.count

        return DailyBrief.Input(
            conversationCount: todayConversations.count,
            messageCount: messageCount,
            windowTokens: windowTokens,
            windowTurns: windowTurns,
            newFactCount: newFacts.count,
            newFactSamples: samples,
            inboxActionCount: inboxCount,
            inboxByTitle: inboxByTitle,
            opsDueToday: dueToday,
            opsOverdue: overdue,
            opsPendingReplies: replySummary.pending,
            opsOverdueReplies: replySummary.overdue,
            opsCampaigns: campaignLines,
            opsAdaptersEnabled: adaptersEnabled,
            opsChannels: channels.count)
    }
}
