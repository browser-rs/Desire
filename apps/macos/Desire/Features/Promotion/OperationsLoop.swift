import Combine
import Foundation
import os

/// 每日运营循环编排层（v0.8.4）：把 OperationsLoopPlan 算出的待办
/// 汇总成一条 Job + routine 通知；可在运营页手动触发或由定时任务驱动。
/// 发布/回复仍走 Agent + 审批，本层只做采集/汇总。
@MainActor
final class OperationsLoop: ObservableObject {
    static let shared = OperationsLoop()

    static let taskName = String(localized: "Operations daily loop")
    private static let lastRunKey = "operations.loop.lastRunAt"

    @Published private(set) var lastReport: OperationsLoopPlan.Report?
    @Published private(set) var isRunning = false

    private init() {}

    var lastRunAt: Date? {
        UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date
    }

    /// 手动触发（▶ 按钮）或定时到点。
    @discardableResult
    func runNow() async -> OperationsLoopPlan.Report? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        let promo = PromotionStore.shared
        let lastRun = lastRunAt

        // 归因摘要（signed in 才有；失败静默——归因是旁路）。
        var attributionDelta: String?
        if case .signedIn = syncStore?.authState {
            attributionDelta = await fetchAttributionDelta()
        }

        let report = OperationsLoopPlan.collect(
            posts: promo.posts,
            campaigns: promo.campaigns,
            interactions: promo.interactions,
            competitorSources: promo.competitorSources,
            attributionDelta: attributionDelta,
            now: Date(),
            lastRunAt: lastRun)

        lastReport = report
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)

        // Jobs 账本：一条汇总 Job。
        let jobID = JobStore.shared.start(
            title: report.headline,
            kind: .other,
            detail: report.items.filter { !$0.isDone }
                .map { "[\($0.kind.label)] \($0.title)" }
                .joined(separator: "\n"),
            source: "operations-loop")
        JobStore.shared.finish(jobID, state: report.actionCount > 0 ? .needsReview : .done,
                               receipt: report.items.filter { !$0.isDone }
                                   .map { "• \($0.title)\n  \($0.detail)" }
                                   .joined(separator: "\n"))

        // Routine 通知：不吵但可见。
        if report.actionCount > 0 {
            ProactiveNotificationStore.shared.deliver(
                title: report.headline,
                body: report.items.filter { !$0.isDone }
                    .prefix(3)
                    .map { $0.title }
                    .joined(separator: " · "),
                tier: .routine)
        }

        Log.agent.info("operations loop: \(report.actionCount) item(s), \(report.overdueCount) overdue")
        return report
    }

    /// 定时任务接线（AgentScheduler builtin）。
    @discardableResult
    func schedule(hour: Int = 9, minute: Int = 0) -> Bool {
        let scheduler = AgentScheduler.shared
        _ = scheduler.remove(named: Self.taskName)
        return scheduler.add(
            name: Self.taskName,
            prompt: "（内置）每日运营循环：采集 + 提及 + 排期 + 回复 + 竞品 + 归因 → 一条收件箱待办",
            recurrence: .daily(hour: hour, minute: minute)) != nil
    }

    func unschedule() {
        _ = AgentScheduler.shared.remove(named: Self.taskName)
    }

    var isScheduled: Bool {
        AgentScheduler.shared.tasks.contains { $0.name == Self.taskName }
    }

    // MARK: - Private

    private var syncStore: SyncStore? { AppState.live?.syncStore }

    /// 归因摘要 delta：拉最新 summary 与上次存的比；无变化/未部署返回 nil。
    private func fetchAttributionDelta() async -> String? {
        guard let sync = syncStore, case .signedIn = sync.authState else { return nil }
        do {
            let summary = try await sync.fetchGrowthSummary(days: 7)
            let encoded = try JSONEncoder().encode(summary.totals)
            let key = "operations.loop.lastAttribution"
            let previous = UserDefaults.standard.data(forKey: key)
            UserDefaults.standard.set(encoded, forKey: key)
            guard let previous,
                  let oldTotals = try? JSONDecoder().decode(GrowthSummary.Totals.self, from: previous) else {
                // 首次：不报变化。
                return nil
            }
            let dv = summary.totals.pageView - oldTotals.pageView
            let dc = summary.totals.downloadClick - oldTotals.downloadClick
            let dl = summary.totals.firstLaunch - oldTotals.firstLaunch
            guard dv != 0 || dc != 0 || dl != 0 else { return nil }
            var parts: [String] = []
            if dv != 0 { parts.append(String(format: String(localized: "+%lld views"), dv)) }
            if dc != 0 { parts.append(String(format: String(localized: "+%lld clicks"), dc)) }
            if dl != 0 { parts.append(String(format: String(localized: "+%lld installs"), dl)) }
            return parts.joined(separator: " · ")
        } catch {
            return nil
        }
    }
}
