import Combine
import Foundation

/// 组订阅持久化（v0.8.39）。watcher 跨回合/跨窗口存活；app 重启后按账本
/// 重新判定（已终态的任务立即汇总一次）。
@MainActor
final class JobWatchStore: ObservableObject {
    static let shared = JobWatchStore()

    struct Delivery {
        let watch: JobWatch
        let jobs: [JobRecord]
    }

    struct Triggered {
        let watch: JobWatch
        let jobs: [JobRecord]
        let kind: JobWatchCondition.Kind
    }

    @Published private(set) var watches: [JobWatch] = []

    private static let storageKey = "jobs.watches"
    private static let maxWatches = 20
    private var pollTimer: Timer?

    private init() {
        watches = DiskStore.load([JobWatch].self, key: Self.storageKey) ?? []
        // 适配器任务（下载/批量/导出/定时）没有显式完成回调：5s 轮询一次账本，
        // 有 watcher 才动作。命令任务另有即时 recordTerminal，轮询是幂等兜底。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    private func poll() {
        guard !active.isEmpty else { return }
        let jobs = JobStore.shared.allJobs
        for trigger in evaluateConditions(jobs: jobs) {
            JobEventCenter.shared.deliver(trigger)
        }
        let deliveries = evaluate(jobs: jobs)
        for delivery in deliveries {
            JobEventCenter.shared.deliver(delivery)
        }
    }

    var active: [JobWatch] { watches.filter { !$0.isDone } }

    func watches(for conversationID: UUID?) -> [JobWatch] {
        guard let conversationID else { return [] }
        return watches.filter { $0.conversationID == conversationID && !$0.isDone }
    }

    func register(jobIDs: [String], conversationID: UUID?,
                  mode: JobWatch.Mode, reason: String?,
                  condition: JobWatchCondition? = nil) -> JobWatch {
        var trimmed = jobIDs
        if trimmed.count > 50 { trimmed = Array(trimmed.prefix(50)) }
        let watch = JobWatch(jobIDs: trimmed, conversationID: conversationID,
                             mode: mode, reason: reason, condition: condition)
        watches.insert(watch, at: 0)
        if watches.count > Self.maxWatches {
            watches.removeLast(watches.count - Self.maxWatches)
        }
        persist()
        return watch
    }

    /// 评估所有未完成 watcher；全部终态的解绑并返回一次 Delivery。
    func evaluate(jobs: [JobRecord]) -> [Delivery] {
        var deliveries: [Delivery] = []
        for index in watches.indices where !watches[index].isDone {
            let watch = watches[index]
            guard JobWatchCore.allSettled(watch, jobs: jobs) else { continue }
            let settled = JobWatchCore.settledJobs(watch, jobs: jobs)
            var states: [String: String] = [:]
            for job in settled {
                states[job.id.uuidString] = job.state.rawValue
            }
            watches[index].deliveredAt = Date()
            watches[index].deliveredStates = states
            deliveries.append(Delivery(watch: watches[index], jobs: settled))
        }
        if !deliveries.isEmpty { persist() }
        return deliveries
    }

    /// 非终态条件评估（v0.8.40）：失败/进度/日志/心跳。触发后 watcher 继续
    /// 存活；终态仍由 evaluate(jobs:) 汇总一次。
    func evaluateConditions(jobs: [JobRecord], now: Date = Date()) -> [Triggered] {
        var triggered: [Triggered] = []
        var changed = false
        for index in watches.indices where !watches[index].isDone {
            let watch = watches[index]
            let tail = logTail(for: watch, jobs: jobs)
            guard let kind = JobWatchCore.event(watch, jobs: jobs,
                                                logTail: tail, now: now),
                  kind != .terminal else { continue }
            watches[index] = JobWatchCore.markingFired(watch, kind: kind, now: now)
            let matching = jobs.filter { watch.jobIDs.contains($0.id.uuidString) }
            triggered.append(Triggered(watch: watches[index], jobs: matching, kind: kind))
            changed = true
        }
        if changed { persist() }
        return triggered
    }

    private func logTail(for watch: JobWatch, jobs: [JobRecord]) -> String? {
        guard watch.effectiveCondition.kind == .logMatch else { return nil }
        let first = jobs.first {
            watch.jobIDs.contains($0.id.uuidString) && $0.logFile != nil
        }
        guard let path = first?.logFile else { return nil }
        return BackgroundCommandStore.readTail(path: path, maxLines: 200)
    }

    func markResumeUsed(_ watchID: UUID) {
        guard let index = watches.firstIndex(where: { $0.id == watchID }) else { return }
        watches[index].resumeUsed = true
        persist()
    }

    func remove(_ id: UUID) {
        watches.removeAll { $0.id == id }
        persist()
    }

    /// 会话删除时清掉它的 watcher（不得写回已删会话）。
    func removeWatches(for conversationID: UUID) {
        watches.removeAll { $0.conversationID == conversationID }
        persist()
    }

    /// 诊断：最近已完成的 watcher（Jobs 面板/桥可看）。
    var recentDelivered: [JobWatch] {
        watches.filter(\.isDone).sorted {
            ($0.deliveredAt ?? .distantPast) > ($1.deliveredAt ?? .distantPast)
        }
    }

    private func persist() {
        DiskStore.save(watches, key: Self.storageKey)
    }
}
