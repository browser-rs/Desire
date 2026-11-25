import Foundation

/// **并发连接数的实测依据**（v0.8.77 批 6，Foundation-only 进 tests/run.sh）。
///
/// CDN 常对单连接限速，所以并发抓分片快；但也可能并发没有增益（出口带宽已经跑满、
/// 或者站点按 IP 限速）——这时多开连接只是徒增被拒的风险。开头的分片顺带量一下：
/// 第 1 个分片单连接抓，随后 N 个并发抓，比较两段的吞吐。
nonisolated enum ParallelTuning {

    struct Evidence: Equatable {
        var singleBytesPerSecond: Double
        var parallelBytesPerSecond: Double
        var connectionsTested: Int
        /// 并发合计是单连接的几倍。
        var gain: Double { singleBytesPerSecond > 0 ? parallelBytesPerSecond / singleBytesPerSecond : 0 }
        /// 给日志看的一句："single connection 160 KB/s, 8 connections 1.10 MB/s (6.9×)"。
        var summary: String {
            "single connection \(rate(singleBytesPerSecond)), \(connectionsTested) connection"
                + (connectionsTested == 1 ? "" : "s") + " \(rate(parallelBytesPerSecond))"
                + " (\(String(format: "%.1f", gain))×)"
        }
    }

    /// 并发合计不到单连接的这个倍数 = 没有增益。
    static let meaningfulGain = 2.0
    /// 没有增益时退到的连接数（仍留一点并发，掩盖单请求的延迟）。
    static let gentleConnections = 4

    /// 实测之后这一路用几个连接，以及给日志看的一句话结论。
    static func connections(requested: Int, evidence: Evidence?,
                            budget: Int) -> (connections: Int, verdict: String) {
        let capped = max(1, min(requested, budget))
        guard let evidence else {
            return (capped, requested > capped ? "connection budget caps \(requested) → \(capped)" : "speed probe skipped")
        }
        if evidence.gain < meaningfulGain, capped > gentleConnections {
            return (gentleConnections, evidence.summary + " — parallel gives no real gain → using \(gentleConnections) connections")
        }
        return (capped, evidence.summary + " → keeping \(capped) connection\(capped == 1 ? "" : "s")")
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 { return String(format: "%.2f MB/s", bytesPerSecond / 1_048_576) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1_024)
    }
}
