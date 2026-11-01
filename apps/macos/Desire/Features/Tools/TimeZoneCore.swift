import Foundation

/// 时区换算（v0.8.33 文本批）：墙钟 ↔ 时刻、偏移、DST。
/// 纯 Foundation、进 tests/run.sh。
nonisolated enum TimeZoneCore {

    static let identifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

    /// `+08:00` / `-04:00`。
    static func offsetString(for zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let absolute = abs(seconds)
        return String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
    }

    static func isDST(for zone: TimeZone, at date: Date) -> Bool {
        zone.isDaylightSavingTime(for: date)
    }

    static func components(for date: Date, in zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    }

    /// 墙钟（源时区）→ 绝对时刻；DST 跳变里不存在的墙钟返回 nil。
    static func instant(wallClock: DateComponents, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: wallClock) else { return nil }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == wallClock.year,
              roundTrip.month == wallClock.month,
              roundTrip.day == wallClock.day,
              roundTrip.hour == wallClock.hour,
              roundTrip.minute == wallClock.minute,
              roundTrip.second == (wallClock.second ?? 0) else { return nil }
        return date
    }

    /// `2026-11-01 09:30:00`（固定格式，便于复制）。
    static func formatted(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 目标时区相对源时区的小时差（同日、含 DST）。
    static func differenceHours(from: TimeZone, to: TimeZone, at date: Date) -> Double {
        Double(to.secondsFromGMT(for: date) - from.secondsFromGMT(for: date)) / 3600
    }
}
