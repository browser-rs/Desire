import Foundation

/// 历史洞察（v0.8.25）：从本地历史派生——总访问、站点数、Top 站点、
/// 24 小时分布、最近 7 天。纯逻辑（进 harness），面板与桥端点同源。
nonisolated struct HistoryInsights: Equatable, Sendable {
    struct Site: Equatable, Sendable {
        var host: String
        var visits: Int
    }

    var totalVisits: Int
    var uniqueSites: Int
    var topSites: [Site]
    /// 0–23 点各时段访问数。
    var hourly: [Int]
    /// 最近 7 天（旧 → 新，最后一个是今天）。
    var lastSevenDays: [Int]
}

nonisolated enum HistoryInsightsBuilder {
    static func host(of url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func build(from entries: [HistoryEntry], now: Date = Date(),
                      calendar: Calendar = .current, topLimit: Int = 10) -> HistoryInsights {
        var perHost: [String: Int] = [:]
        var hourly = Array(repeating: 0, count: 24)
        var days = Array(repeating: 0, count: 7)
        let today = calendar.startOfDay(for: now)
        var total = 0

        for entry in entries {
            let visits = max(1, entry.visitCount)
            total += visits
            if let host = host(of: entry.url) {
                perHost[host, default: 0] += visits
            }
            let hour = calendar.component(.hour, from: entry.timestamp)
            if hourly.indices.contains(hour) { hourly[hour] += visits }
            let day = calendar.startOfDay(for: entry.timestamp)
            let offset = calendar.dateComponents([.day], from: day, to: today).day ?? 99
            if (0..<7).contains(offset) {
                days[6 - offset] += visits
            }
        }

        let top = perHost
            .map { HistoryInsights.Site(host: $0.key, visits: $0.value) }
            .sorted { lhs, rhs in
                lhs.visits != rhs.visits ? lhs.visits > rhs.visits : lhs.host < rhs.host
            }
            .prefix(max(1, topLimit))

        return HistoryInsights(totalVisits: total,
                               uniqueSites: perHost.count,
                               topSites: Array(top),
                               hourly: hourly,
                               lastSevenDays: days)
    }
}
