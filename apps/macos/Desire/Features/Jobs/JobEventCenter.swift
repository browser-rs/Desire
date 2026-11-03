import Foundation

/// 后台任务终态的唯一交付口（v0.8.39）。
///
/// 规则：
/// - 被 watcher 覆盖的任务**不**单独发备注/通知，等组 watcher 汇总一次；
/// - 未被覆盖的命令任务，完成时给发起会话写备注 + 系统通知；
/// - 组 watcher 全部终态后写一条汇总备注 + 一次通知；`resume` 模式在会话
///   空闲时再起一轮“汇报结果”的短回合（每组一次）。
/// - 所有路径都只处理终态；重复调用由 runner 的完成闸与 watcher deliveredAt 挡住。
@MainActor
final class JobEventCenter {
    static let shared = JobEventCenter()

    private init() {}

    /// 任务刚进入终态时调用（JobStore 已写好 state/exitCode/artifact）。
    func recordTerminal(jobID: UUID) {
        guard let job = JobStore.shared.job(id: jobID), job.isTerminal else { return }
        let watched = JobWatchStore.shared.active.contains {
            $0.jobIDs.contains(jobID.uuidString)
        }
        if !watched {
            deliverIndividual(job)
        }
        let deliveries = JobWatchStore.shared.evaluate(jobs: JobStore.shared.allJobs)
        for delivery in deliveries {
            deliverGroup(delivery)
        }
    }

    /// 启动/重启时补交付已终态但 watcher 还挂着的任务（例如 app 重启后
    /// 命令被标 interrupted）。也清理已删会话的 watcher。
    func reconcileAtLaunch() {
        for watch in JobWatchStore.shared.watches where !watch.isDone {
            if let conversationID = watch.conversationID,
               !conversationExists(conversationID) {
                JobWatchStore.shared.remove(watch.id)
            }
        }
        let deliveries = JobWatchStore.shared.evaluate(jobs: JobStore.shared.allJobs)
        for delivery in deliveries {
            deliverGroup(delivery)
        }
    }

    // MARK: - 单任务

    private func deliverIndividual(_ job: JobRecord) {
        let summary = JobSummaryCore.summary(for: [job])
        if let conversationID = job.conversationID {
            appendNote(summary, to: conversationID)
        }
        let failed = job.state == .failed
        ProactiveNotificationStore.shared.deliverJob(
            title: failed
                ? String(localized: "Background task failed: \(job.title)")
                : String(localized: "Background task finished: \(job.title)"),
            body: String(summary.prefix(240)),
            tier: failed ? .urgent : .routine,
            jobID: job.id,
            artifact: job.artifactURL)
        AppState.live?.remoteControlStore.notifyBackgroundJob(
            id: job.id,
            title: failed ? String(localized: "Background task failed: \(job.title)")
                : String(localized: "Background task finished: \(job.title)"),
            body: summary,
            failed: failed,
            artifact: job.artifactURL)
    }

    // MARK: - 组任务

    private func deliverGroup(_ delivery: JobWatchStore.Delivery) {
        deliver(delivery)
    }

    /// 适配器任务（批量下载/媒体导出）终态：外部系统已经生成好人类可读的
    /// 汇总（成功/失败/跳过），这里只负责“有没有 watcher”与去重后的交付。
    /// 没找到对应 JobRecord 时退回旧行为（当前会话备注 + 通知）。
    func recordExternalTerminal(externalID: String, title: String, body: String,
                                tier: NotificationTier,
                                artifact: String? = nil) {
        let jobs = JobStore.shared.allJobs
        guard let job = jobs.first(where: {
            $0.externalID == externalID || $0.id.uuidString == externalID
        }) else {
            AgentScheduler.shared.deliveryTarget?.appendExternalNote("\(title): \(body)")
            ProactiveNotificationStore.shared.deliver(title: title, body: body, tier: tier)
            return
        }
        let watched = JobWatchStore.shared.active.contains {
            $0.jobIDs.contains(job.id.uuidString)
        }
        if watched {
            let deliveries = JobWatchStore.shared.evaluate(jobs: JobStore.shared.allJobs)
            for delivery in deliveries {
                deliver(delivery, summaryOverride: delivery.jobs.contains(where: {
                    $0.id == job.id
                }) ? body : nil)
            }
            return
        }
        if let conversationID = job.conversationID {
            appendNote("\(title): \(body)", to: conversationID)
        } else {
            AgentScheduler.shared.deliveryTarget?.appendExternalNote("\(title): \(body)")
        }
        ProactiveNotificationStore.shared.deliver(title: title, body: body, tier: tier)
    }

    /// 非终态条件触发（失败/进度/日志/心跳）：发一次提醒，watcher 继续等终态。
    func deliver(_ trigger: JobWatchStore.Triggered) {
        let job = trigger.jobs.first
        let title: String
        switch trigger.kind {
        case .failed:
            title = String(localized: "Background task failed: \(job?.title ?? "Job")")
        case .progress:
            title = String(localized: "Background task progress: \(job?.title ?? "Job")")
        case .logMatch:
            title = String(localized: "Background log matched: \(job?.title ?? "Job")")
        case .heartbeat:
            title = String(localized: "Still running: \(job?.title ?? "Job")")
        case .terminal:
            return
        }
        var summary = JobSummaryCore.summary(for: trigger.jobs)
        summary += "\n" + String(localized: "Condition: \(JobWatchCore.conditionDescription(trigger.watch.effectiveCondition))")
        if let conversationID = trigger.watch.conversationID {
            appendNote(summary, to: conversationID)
        }
        let failed = trigger.kind == .failed
        ProactiveNotificationStore.shared.deliverJob(
            title: title, body: String(summary.prefix(240)),
            tier: failed ? .urgent : .routine,
            jobID: job?.id ?? UUID(), artifact: job?.artifactURL)
        if let first = job {
            AppState.live?.remoteControlStore.notifyBackgroundJob(
                id: first.id, title: title, body: summary,
                failed: failed, artifact: first.artifactURL)
        }
        if failed, trigger.watch.mode == .resume,
           let conversationID = trigger.watch.conversationID {
            maybeResume(
                JobWatchStore.Delivery(watch: trigger.watch, jobs: trigger.jobs),
                summary: summary)
            _ = conversationID
        }
    }

    /// 组 watcher 已判定完成 → 交付备注/通知（轮询与即时事件共用）。
    /// `summaryOverride` 用于批量/媒体已有的富文本汇总（成功/失败/跳过）。
    func deliver(_ delivery: JobWatchStore.Delivery, summaryOverride: String? = nil) {
        let summary = summaryOverride ?? JobSummaryCore.summary(for: delivery.jobs)
        let failed = delivery.jobs.contains { $0.state == .failed }
        let title = delivery.jobs.count == 1
            ? (delivery.jobs.first?.title ?? String(localized: "Background task"))
            : String(localized: "\(delivery.jobs.count) background tasks finished")
        if let conversationID = delivery.watch.conversationID {
            appendNote(summary, to: conversationID)
            maybeResume(delivery, summary: summary)
        }
        ProactiveNotificationStore.shared.deliverJob(
            title: failed
                ? String(localized: "Background tasks failed: \(title)")
                : String(localized: "Background tasks finished: \(title)"),
            body: String(summary.prefix(240)),
            tier: failed ? .urgent : .routine,
            jobID: delivery.jobs.first?.id ?? UUID(),
            artifact: delivery.jobs.compactMap(\.artifactURL).first)
        if let first = delivery.jobs.first {
            AppState.live?.remoteControlStore.notifyBackgroundJob(
                id: first.id, title: title, body: summary,
                failed: failed,
                artifact: delivery.jobs.compactMap(\.artifactURL).first)
        }
    }

    private func maybeResume(_ delivery: JobWatchStore.Delivery, summary: String) {
        guard let conversationID = delivery.watch.conversationID,
              let session = liveSession(for: conversationID) else { return }
        let canResume = JobWatchCore.canResume(
            delivery.watch, sessionExists: true, sessionBusy: session.isProcessing)
        JobWatchStore.shared.markResumeUsed(delivery.watch.id)
        guard canResume else { return }
        session.sendMessage(
            String(localized: "Background tasks finished. Briefly report the outcome to me using the completion note above — include failures and output paths. Do not start new work unless I ask."),
            recordHistory: false)
    }

    // MARK: - 会话写入

    private func appendNote(_ text: String, to conversationID: UUID) {
        if let session = liveSession(for: conversationID) {
            session.appendExternalNote(text)
            return
        }
        // 会话没开（窗口关了/切走了）：直接写回盘上的会话，下次打开能看到。
        guard let app = AppState.live,
              var conversation = app.conversationStore.conversation(for: conversationID) else {
            return
        }
        conversation.messages.append(AgentMessage(role: .system, content: text))
        conversation.updatedAt = Date()
        app.conversationStore.save(conversation)
    }

    private func liveSession(for conversationID: UUID) -> AgentSessionStore? {
        AgentScheduler.shared.liveSessions()
            .compactMap(\.store)
            .first { $0.conversationId == conversationID }
    }

    private func conversationExists(_ id: UUID) -> Bool {
        guard let app = AppState.live else { return false }
        return app.conversationStore.conversation(for: id) != nil
    }
}
