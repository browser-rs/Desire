import Foundation

/// **下载记录**（v0.8.79 批 2，Foundation-only 进 tests/run.sh）：从已保存的批次
/// 派生"按站点"的成败与吞吐，不另存一份统计。设置页的下载记录小节与桥
/// `GET /downloads/history` 同源。
///
/// 口径（与 `BatchMediaLog` 的批次日志保持一致）：
/// - 只统计**已落定**的条目（finished / failed / skipped）；pending 等不计，
///   所以运行中的批次不会把分母提前撑大。
/// - 站点 = 条目来源页的主机（详情页），不是媒体 CDN 的主机。
/// - 体积只累加成功产物；平均速度 = 成功条目字节和 / 成功条目耗时和（两项都有值才算）。
/// - 批次列表覆盖进程内可见的批次（含恢复的最近 12 个完成批次）；更早的批次日志
///   已归档，不在本视图范围。
nonisolated struct DownloadHistory: Equatable {
    struct Site: Identifiable, Equatable {
        var id: String { host }
        let host: String
        var batches: Int = 0
        var items: Int = 0
        var finished: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        var bytes: Int64 = 0
        var timedItems: Int = 0
        var totalSeconds: Double = 0
        var engines: [String: Int] = [:]
        /// 最近一次成功用到的连接数（并发路径）。
        var connections: Int?
        var lastAt: Date?
        var lastFailure: String?
        /// 最近失败所属批次的时间（内部排序用）。
        var lastFailureAt: Date?

        var averageSeconds: Double? {
            timedItems > 0 ? totalSeconds / Double(timedItems) : nil
        }

        var averageBytesPerSecond: Double? {
            guard timedItems > 0, totalSeconds > 0, bytes > 0 else { return nil }
            return Double(bytes) / totalSeconds
        }

        /// 只提示、不换路（v0.8.79）：同一站点近期失败 ≥2 且不比成功少时，
        /// 提醒先看看规则/签名/连接数，不要盲目重跑。
        var hint: String? {
            guard failed >= 2, failed >= finished else { return nil }
            var text = "\(host): \(failed) failed vs \(finished) finished recently"
            if let lastFailure, !lastFailure.isEmpty {
                text += " (last: \(lastFailure.prefix(120)))"
            }
            text += " — check the site rule or the page's fresh URL instead of retrying blindly"
            return text
        }
    }

    struct Batch: Identifiable, Equatable {
        let id: UUID
        let createdAt: Date
        let state: String
        let folder: String
        var items: Int = 0
        var finished: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        var bytes: Int64 = 0
        var engines: [String: Int] = [:]
    }

    var sites: [Site] = []
    var batches: [Batch] = []
    var finished: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    var bytes: Int64 = 0

    /// 从批次列表派生（最近在前）。纯函数：批次顺序不影响结果。
    static func derive(from batches: [BatchMediaBatch]) -> DownloadHistory {
        var history = DownloadHistory()
        var sites: [String: Site] = [:]

        for batch in batches.sorted(by: { $0.createdAt > $1.createdAt }) {
            var record = Batch(id: batch.id, createdAt: batch.createdAt,
                               state: batch.state.rawValue, folder: batch.folderName)
            var seenSites = Set<String>()
            var reasonsInBatch: [String: String] = [:]
            for item in batch.items {
                guard item.state != .pending, item.state != .resolving,
                      item.state != .needsHuman, item.state != .downloading else { continue }
                let host = item.sourceURL.host ?? "unknown"
                var site = sites[host] ?? Site(host: host)
                if seenSites.insert(host).inserted { site.batches += 1 }
                site.items += 1
                record.items += 1
                if site.lastAt == nil || batch.createdAt > site.lastAt! {
                    site.lastAt = batch.createdAt
                }
                switch item.state {
                case .finished:
                    site.finished += 1
                    record.finished += 1
                    history.finished += 1
                    let size = item.bytes ?? 0
                    site.bytes += size
                    record.bytes += size
                    history.bytes += size
                    if let seconds = item.seconds, seconds > 0 {
                        site.timedItems += 1
                        site.totalSeconds += seconds
                    }
                    if let engine = item.engine, !engine.isEmpty {
                        site.engines[engine, default: 0] += 1
                        record.engines[engine, default: 0] += 1
                        if let connections = item.connections { site.connections = connections }
                    }
                case .failed:
                    site.failed += 1
                    record.failed += 1
                    history.failed += 1
                    if let reason = item.failureReason, !reason.isEmpty {
                        reasonsInBatch[host] = reason
                    }
                case .skipped:
                    site.skipped += 1
                    record.skipped += 1
                    history.skipped += 1
                default:
                    break
                }
                sites[host] = site
            }
            // 最近失败原因取**最新失败批次**里的最后一条（批次按时间倒序处理，
            // 不能每遇到一个失败项就覆盖——最早那批会把最新的盖掉）。
            for (host, reason) in reasonsInBatch {
                guard var site = sites[host] else { continue }
                if let current = site.lastFailureAt, current >= batch.createdAt { continue }
                site.lastFailure = reason
                site.lastFailureAt = batch.createdAt
                sites[host] = site
            }
            history.batches.append(record)
        }

        history.sites = sites.values.sorted { lhs, rhs in
            lhs.failed != rhs.failed ? lhs.failed > rhs.failed : lhs.host < rhs.host
        }
        return history
    }
}
