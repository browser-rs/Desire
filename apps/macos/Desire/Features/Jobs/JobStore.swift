import Combine
import Foundation

/// 统一作业账本（v0.8.2）：跨运营/发布/扫描/后续后台任务的交付视图。
/// 与各子系统自己的状态分开——这里只回答“我让它做的事到哪了、产物在哪、
/// 有没有回执”。新作业通过 `start`/`update`/`finish` 写入；旧子系统等后续
/// 通过 adapter 读取（本批先接发布准备与提及扫描）。
@MainActor
final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published private(set) var jobs: [JobRecord] = []

    private static let storageKey = "ops.jobs"
    private static let maxJobs = 300

    private init() {
        jobs = DiskStore.load([JobRecord].self, key: Self.storageKey) ?? []
    }

    // MARK: - 查询

    func job(id: UUID) -> JobRecord? { jobs.first { $0.id == id } }

    /// 旧子系统的只读投影（下载/批量/导出/定时/Agent/crew）。
    /// 1 秒缓存：Jobs 面板一次渲染会取多份列表，避免反复扫全部 store。
    private var adapterCache: (at: Date, jobs: [JobRecord])?

    var adapterJobs: [JobRecord] {
        if let cache = adapterCache, Date().timeIntervalSince(cache.at) < 1 {
            return cache.jobs
        }
        let jobs = JobAdapter.jobs(from: ActivityCenter.build(ActivityCenterCollector.liveInputs()))
        adapterCache = (Date(), jobs)
        return jobs
    }

    /// 账本 + 旧子系统投影，统一按更新时间倒序。
    var allJobs: [JobRecord] {
        (jobs + adapterJobs).sorted { $0.updatedAt > $1.updatedAt }
    }

    var active: [JobRecord] {
        allJobs.filter { $0.state.isActive }
    }

    var needsReview: [JobRecord] {
        allJobs.filter { $0.state == .needsReview || $0.state == .needsApproval }
    }

    var failed: [JobRecord] {
        allJobs.filter { $0.state == .failed }
    }

    var finished: [JobRecord] {
        allJobs.filter { $0.state == .done || $0.state == .cancelled }
    }

    // MARK: - 写入

    @discardableResult
    func start(title: String, kind: JobRecord.Kind, detail: String = "",
               source: String? = nil, externalID: String? = nil) -> UUID {
        let now = Date()
        let job = JobRecord(title: title, kind: kind, state: .running,
                            detail: detail, source: source, externalID: externalID,
                            createdAt: now, updatedAt: now)
        jobs.insert(job, at: 0)
        trim()
        save()
        return job.id
    }

    func update(_ id: UUID, state: JobRecord.State? = nil,
                detail: String? = nil, progress: Double? = nil,
                artifactURL: String? = nil, receipt: String? = nil,
                error: String? = nil) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        if let state {
            jobs[idx].state = state
            if !state.isActive, jobs[idx].finishedAt == nil {
                jobs[idx].finishedAt = Date()
            }
        }
        if let detail { jobs[idx].detail = detail }
        if let progress { jobs[idx].progress = max(0, min(1, progress)) }
        if let artifactURL { jobs[idx].artifactURL = artifactURL }
        if let receipt { jobs[idx].receipt = receipt }
        if let error { jobs[idx].error = error }
        jobs[idx].updatedAt = Date()
        save()
    }

    func finish(_ id: UUID, state: JobRecord.State,
                receipt: String? = nil, artifactURL: String? = nil,
                error: String? = nil) {
        update(id, state: state, progress: 1,
               artifactURL: artifactURL, receipt: receipt, error: error)
    }

    /// 取消/丢弃（不声称底层任务已停止；仅从活动视图移除）。
    func dismiss(_ id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }),
              jobs[idx].state.isActive else { return }
        jobs[idx].state = .cancelled
        jobs[idx].detail = String(localized: "Dismissed — the underlying task may still be running.")
        jobs[idx].updatedAt = Date()
        jobs[idx].finishedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        jobs.removeAll { $0.id == id }
        save()
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled }
        save()
    }

    /// 发布成功回写：找到该帖最新的活动发布作业，标 done 并记 URL。
    func completePublishJob(for postID: UUID, url: String?) {
        guard let idx = jobs.firstIndex(where: {
            $0.kind == .publish && $0.externalID == postID.uuidString
                && $0.state.isActive
        }) else { return }
        jobs[idx].state = .done
        jobs[idx].artifactURL = url
        jobs[idx].receipt = url.map { String(localized: "Published: \($0)") }
            ?? String(localized: "Marked published")
        jobs[idx].updatedAt = Date()
        jobs[idx].finishedAt = Date()
        save()
    }

    private func trim() {
        if jobs.count > Self.maxJobs {
            // 只淘汰最旧的终态作业；活动作业绝不因容量被丢。
            let terminal = jobs.filter(\.isTerminal).sorted { $0.updatedAt < $1.updatedAt }
            let overflow = jobs.count - Self.maxJobs
            let doomed = Set(terminal.prefix(max(0, overflow)).map(\.id))
            jobs.removeAll { doomed.contains($0.id) }
        }
    }

    private func save() {
        DiskStore.save(jobs, key: Self.storageKey)
    }
}
