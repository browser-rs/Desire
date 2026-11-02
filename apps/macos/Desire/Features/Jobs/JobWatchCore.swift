import Foundation

/// 组订阅的判定与汇总（v0.8.39，纯逻辑进 tests/run.sh）。
nonisolated enum JobWatchCore {
    /// 注册前校验：ids 与 kind 二选一；ids 非空且 ≤50；mode 合法。
    static func validationError(ids: [UUID], kind: String?,
                                mode: JobWatch.Mode) -> String? {
        if ids.isEmpty && (kind?.isEmpty ?? true) {
            return String(localized: "Give a job id or a kind to watch.")
        }
        if !ids.isEmpty && !(kind?.isEmpty ?? true) {
            return String(localized: "Pass either job ids or a kind, not both.")
        }
        if ids.count > 50 {
            return String(localized: "Watch at most 50 jobs at once.")
        }
        return nil
    }

    /// 快照要盯的任务：显式 ids 原样取；kind 取当前活动任务（注册后新出现的
    /// 不并入——否则“永远等不完”）。
    static func snapshot(ids: [UUID], kind: String?,
                         jobs: [JobRecord]) -> [JobRecord] {
        if !ids.isEmpty {
            let wanted = Set(ids.map(\.uuidString))
            return jobs.filter { wanted.contains($0.id.uuidString) }
        }
        guard let kind, !kind.isEmpty else { return [] }
        return jobs.filter {
            guard $0.state.isActive else { return false }
            if kind == "batch" {
                return $0.kind == .download
                    && ($0.externalID?.hasPrefix("batch-") ?? false)
            }
            return $0.kind.rawValue == kind
        }
    }

    /// 组内是否全部终态。缺失的 job（被删除/适配器消失）按 cancelled 视为终态，
    /// 否则 watcher 会永远挂着。
    static func allSettled(_ watch: JobWatch, jobs: [JobRecord]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id.uuidString, $0) })
        return watch.jobIDs.allSatisfy { id in
            guard let job = byID[id] else { return true }
            return !job.state.isActive
        }
    }

    /// 已终态的 job（用于汇总）；缺失的任务合成一条 cancelled 记录。
    static func settledJobs(_ watch: JobWatch, jobs: [JobRecord]) -> [JobRecord] {
        let byID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id.uuidString, $0) })
        return watch.jobIDs.map { id in
            if let job = byID[id] { return job }
            return JobRecord(
                id: UUID(uuidString: id) ?? UUID(),
                title: String(localized: "Deleted task"),
                kind: .other,
                state: .cancelled,
                detail: String(localized: "The task is no longer in the job ledger."),
                updatedAt: Date(), finishedAt: Date())
        }
    }

    /// 是否允许起 resume 回合：会话仍存在、没有在跑、没有被暂停/取消、且没用过。
    static func canResume(_ watch: JobWatch, sessionExists: Bool,
                          sessionBusy: Bool) -> Bool {
        watch.mode == .resume && !watch.resumeUsed && sessionExists && !sessionBusy
    }
}

/// 终态汇总（v0.8.39，纯逻辑）。单任务与组任务共用，限制长度避免撑爆备注。
nonisolated enum JobSummaryCore {
    static let maxChars = 1_200

    static func summary(for jobs: [JobRecord]) -> String {
        guard !jobs.isEmpty else { return String(localized: "No background tasks.") }
        let done = jobs.filter { $0.state == .done }.count
        let failed = jobs.filter { $0.state == .failed }.count
        let cancelled = jobs.filter { $0.state == .cancelled }.count
        let skipped = jobs.count - done - failed - cancelled
        var parts: [String] = []
        if jobs.count == 1, let job = jobs.first {
            parts.append("\(job.title): \(job.state.label)")
        } else {
            var headline = String(localized: "\(jobs.count) tasks finished")
            headline += " — \(done) done"
            if failed > 0 { headline += ", \(failed) failed" }
            if cancelled > 0 { headline += ", \(cancelled) cancelled" }
            if skipped > 0 { headline += ", \(skipped) other" }
            parts.append(headline)
        }
        let started = jobs.map(\.createdAt).min()
        let finished = jobs.compactMap(\.finishedAt).max() ?? Date()
        if let started, finished > started {
            parts.append(String(localized: "Elapsed: \(Int(finished.timeIntervalSince(started)))s"))
        }
        let artifacts = jobs.compactMap(\.artifactURL).filter { !$0.isEmpty }
        if !artifacts.isEmpty {
            parts.append(String(localized: "Output: ")
                + artifacts.prefix(5).map { shorten($0, 120) }.joined(separator: "; "))
        }
        let failures = jobs.filter { $0.state == .failed }
        if !failures.isEmpty {
            parts.append(String(localized: "Failed: ")
                + failures.prefix(5).map {
                    shorten($0.title, 60) + ($0.error.map { " (\(shorten($0, 80)))" } ?? "")
                }.joined(separator: "; "))
        }
        let commands = jobs.filter { $0.kind == .command }
        for command in commands.prefix(3) {
            var line = "\(shorten(command.title, 60)): exit \(command.exitCode ?? -1)"
            if let log = command.logFile, !log.isEmpty {
                line += String(localized: " — log: \(log)")
            }
            parts.append(line)
        }
        return shorten(parts.joined(separator: "\n"), maxChars)
    }

    private static func shorten(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
