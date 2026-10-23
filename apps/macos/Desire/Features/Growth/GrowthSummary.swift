import Foundation

/// 归因聚合（v0.8.3）：desire-api `/growth/summary` 的客户端模型。
/// 只含匿名计数（无 IP/Cookie/PII）；日期由服务端按 UTC 分组。
nonisolated struct GrowthSummary: Codable, Equatable {
    struct Totals: Codable, Equatable {
        var pageView: Int
        var downloadClick: Int
        var firstLaunch: Int

        var total: Int { pageView + downloadClick + firstLaunch }

        private enum CodingKeys: String, CodingKey {
            case pageView = "page_view"
            case downloadClick = "download_click"
            case firstLaunch = "first_launch"
        }
    }

    struct Day: Codable, Equatable, Identifiable {
        var day: String
        var pageView: Int
        var downloadClick: Int
        var firstLaunch: Int

        var id: String { day }

        private enum CodingKeys: String, CodingKey {
            case day
            case pageView = "page_view"
            case downloadClick = "download_click"
            case firstLaunch = "first_launch"
        }
    }

    struct Breakdown: Codable, Equatable, Identifiable {
        var key: String
        var pageView: Int
        var downloadClick: Int
        var firstLaunch: Int

        var id: String { key }
        var total: Int { pageView + downloadClick + firstLaunch }

        private enum CodingKeys: String, CodingKey {
            case key
            case pageView = "page_view"
            case downloadClick = "download_click"
            case firstLaunch = "first_launch"
        }
    }

    var days: Int
    var totals: Totals
    var daily: [Day]
    var campaigns: [Breakdown]
    var sources: [Breakdown]
    var lastEventAt: String?

    enum CodingKeys: String, CodingKey {
        case days, totals, daily, campaigns, sources
        case lastEventAt = "last_event_at"
    }

    /// 下载点击 / 页面浏览（分母为 0 = nil，不编造 0%）。
    var clickRate: Double? {
        guard totals.pageView > 0 else { return nil }
        return Double(totals.downloadClick) / Double(totals.pageView)
    }

    /// 首次启动 / 下载点击。
    var installRate: Double? {
        guard totals.downloadClick > 0 else { return nil }
        return Double(totals.firstLaunch) / Double(totals.downloadClick)
    }

    var isEmpty: Bool { totals.total == 0 }

    /// 补零成连续的日期序列（服务端只返回有事件的日期）；用于折线图。
    static func paddedDaily(_ summary: GrowthSummary) -> [Day] {
        guard let newest = summary.daily.last?.day,
              let newestDate = parseDay(newest),
              let oldest = summary.daily.first?.day,
              let oldestDate = parseDay(oldest) else {
            return summary.daily
        }
        var byDay: [String: Day] = [:]
        for day in summary.daily { byDay[day.day] = day }
        var out: [Day] = []
        var cursor = oldestDate
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        while cursor <= newestDate {
            let key = formatDay(cursor)
            out.append(byDay[key] ?? Day(day: key, pageView: 0, downloadClick: 0, firstLaunch: 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    nonisolated static func parseDay(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    nonisolated static func formatDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
