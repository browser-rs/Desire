import Foundation

/// 定时任务审计聚合（v0.8.10 基础件）：按任务名聚合窗口内的运行——次数/
/// 成功率/平均耗时/最后错误。输入是轻量行（调用方从 RunRecord 折出），
/// 本文件 Foundation-only 进 harness。
nonisolated enum TaskRunAudit {
    struct Audit: Identifiable, Equatable {
        var id: String { taskName }
        let taskName: String
        let totalRuns: Int
        let failures: Int
        let averageSeconds: Double?
        let lastError: String?
        let lastFiredAt: Date?

        var failureRate: Double { totalRuns > 0 ? Double(failures) / Double(totalRuns) : 0 }
    }

    struct Row: Equatable {
        let taskName: String
        let firedAt: Date
        let finishedAt: Date?
        let failed: Bool
        let error: String?
    }

    static func derive(rows: [Row], now: Date = Date(), days: Int = 30) -> [Audit] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var acc: [String: (total: Int, failures: Int, sum: Double, samples: Int, lastError: String?, lastAt: Date?)] = [:]
        for r in rows where r.firedAt >= cutoff {
            var a = acc[r.taskName] ?? (0, 0, 0, 0, nil, nil)
            a.total += 1
            if r.failed {
                a.failures += 1
                if let e = r.error, !e.isEmpty { a.lastError = e }
            }
            if let fin = r.finishedAt, fin > r.firedAt {
                a.sum += fin.timeIntervalSince(r.firedAt)
                a.samples += 1
            }
            if a.lastAt == nil || r.firedAt > (a.lastAt ?? .distantPast) { a.lastAt = r.firedAt }
            acc[r.taskName] = a
        }
        return acc.map { name, a in
            Audit(taskName: name, totalRuns: a.total, failures: a.failures,
                  averageSeconds: a.samples > 0 ? a.sum / Double(a.samples) : nil,
                  lastError: a.lastError, lastFiredAt: a.lastAt)
        }
        .sorted { $0.totalRuns > $1.totalRuns }
    }
}
