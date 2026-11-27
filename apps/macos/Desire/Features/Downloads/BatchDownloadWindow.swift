import Foundation

/// 批量下载的**时段窗口**（v0.8.80 批 5）：只在设定时段内跑，支持跨午夜
/// （22:00–06:00）、总时长上限与批内并发上限。纯逻辑（Foundation-only），
/// harness 直测；到点自动开始/暂停由 `BatchMediaExportStore` 的监视器执行。
nonisolated struct BatchDownloadWindow: Codable, Equatable, Sendable {
    /// 本地时间分钟数（0…1439）。
    var startMinute: Int
    var endMinute: Int
    /// 总时长上限（分钟；0 = 不限）。每次进入窗口重新计时。
    var maxDurationMinutes: Int
    /// 批内并发上限（0 = 跟随全局）。
    var maxConcurrent: Int

    init(startMinute: Int, endMinute: Int, maxDurationMinutes: Int = 0, maxConcurrent: Int = 0) {
        self.startMinute = min(max(startMinute, 0), 1439)
        self.endMinute = min(max(endMinute, 0), 1439)
        self.maxDurationMinutes = max(0, maxDurationMinutes)
        self.maxConcurrent = min(max(maxConcurrent, 0), 16)
    }

    /// "02:00–08:00" 解析（也接受 "2:00"）；失败返回 nil。
    init?(start: String, end: String, maxDurationMinutes: Int = 0, maxConcurrent: Int = 0) {
        guard let s = Self.parseMinute(start), let e = Self.parseMinute(end) else { return nil }
        self.init(startMinute: s, endMinute: e,
                  maxDurationMinutes: maxDurationMinutes, maxConcurrent: maxConcurrent)
    }

    /// start == end = 全天；start > end = 跨午夜。
    func isOpen(at date: Date, calendar: Calendar = .current) -> Bool {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinute == endMinute { return true }
        if startMinute < endMinute {
            return now >= startMinute && now < endMinute
        }
        return now >= startMinute || now < endMinute
    }

    /// 距离下一次开窗的分钟数（0 = 现在就开着）。
    func minutesUntilOpen(from date: Date, calendar: Calendar = .current) -> Int {
        if isOpen(at: date, calendar: calendar) { return 0 }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        var wait = startMinute - now
        if wait <= 0 { wait += 24 * 60 }
        return wait
    }

    /// 本次开窗是否已到总时长上限。
    func durationExceeded(startedAt: Date?, now: Date = Date()) -> Bool {
        guard maxDurationMinutes > 0, let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= Double(maxDurationMinutes * 60)
    }

    var startText: String { Self.format(startMinute) }
    var endText: String { Self.format(endMinute) }

    /// "02:00–08:00 · 最多 6h · 4 并发"（界面与回执共用）。
    var summary: String {
        var parts = ["\(startText)–\(endText)"]
        if maxDurationMinutes > 0 {
            let hours = Double(maxDurationMinutes) / 60
            parts.append(hours == hours.rounded()
                         ? "max \(Int(hours))h" : String(format: "max %.1fh", hours))
        }
        if maxConcurrent > 0 { parts.append("\(maxConcurrent) concurrent") }
        return parts.joined(separator: " · ")
    }

    static func parseMinute(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func format(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
