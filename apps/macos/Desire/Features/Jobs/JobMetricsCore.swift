import Foundation

/// Jobs 中心的历史指标（v0.8.40）：从 JobRecord 派生，不另存一份。
nonisolated enum JobMetricsCore {
    struct Snapshot {
        var total: Int
        var done: Int
        var failed: Int
        var cancelled: Int
        /// done / (done + failed)；没有可判定样本 = nil。
        var successRate: Double?
        var averageDuration: TimeInterval?
        var topFailures: [(kind: String, count: Int)]
    }

    static func today(_ jobs: [JobRecord], now: Date = Date(),
                      calendar: Calendar = .current) -> Snapshot {
        let todays = jobs.filter { calendar.isDate($0.updatedAt, inSameDayAs: now) }
        return derive(todays)
    }

    static func derive(_ jobs: [JobRecord]) -> Snapshot {
        let done = jobs.filter { $0.state == .done }.count
        let failed = jobs.filter { $0.state == .failed }.count
        let cancelled = jobs.filter { $0.state == .cancelled }.count
        let judged = done + failed
        let durations = jobs.compactMap { job -> TimeInterval? in
            guard let finished = job.finishedAt, finished > job.createdAt else { return nil }
            return finished.timeIntervalSince(job.createdAt)
        }
        var failureCounts: [String: Int] = [:]
        for job in jobs where job.state == .failed {
            failureCounts[job.kind.rawValue, default: 0] += 1
        }
        let top = failureCounts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(3).map { (kind: $0.key, count: $0.value) }
        return Snapshot(
            total: jobs.count,
            done: done,
            failed: failed,
            cancelled: cancelled,
            successRate: judged > 0 ? Double(done) / Double(judged) : nil,
            averageDuration: durations.isEmpty
                ? nil : durations.reduce(0, +) / Double(durations.count),
            topFailures: Array(top))
    }
}
