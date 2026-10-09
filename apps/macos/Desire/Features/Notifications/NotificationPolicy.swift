import Foundation

/// 主动通知的两档分级（2026-10-09，对齐 Dots/Muse 这类常驻代理"帮助与
/// 骚扰一线之隔"的教训）：routine（页面监视、完成汇总——可批量合并）与
/// urgent（无人值守失败等——任何时刻都立即推）。
enum NotificationTier: String {
    case routine
    case urgent
}

/// 通知策略（**纯逻辑半边**）：免打扰时段（支持跨午夜）+ 每日 routine 预算。
/// 免打扰时段内或超预算的 routine 通知被扣下合并成一条摘要，免打扰结束
/// （或桥手动 flush）时补推；urgent 永远直推。持久化与系统通知在
/// `ProactiveNotificationStore`。
///
/// Foundation-only：时段运算/预算判定/摘要拼装进 tests/run.sh 回归。
/// nonisolated：纯数据 + 纯函数（同 AgentGuard 的理由）。
nonisolated struct NotificationPolicy: Codable, Equatable {
    var quietHoursEnabled: Bool = false
    /// 当日分钟数。start > end = 跨午夜时段（默认 23:00–08:00）。
    var quietStartMinute: Int = 23 * 60
    var quietEndMinute: Int = 8 * 60
    /// routine 通知的每日预算；0 = 不限。超预算 → 扣进摘要。
    var dailyRoutineLimit: Int = 12

    /// start == end 视为"无免打扰时段"（避免 24h 与 0h 两种解读打架）。
    func isQuietTime(minutesSinceMidnight: Int) -> Bool {
        guard quietHoursEnabled, quietStartMinute != quietEndMinute else { return false }
        let m = ((minutesSinceMidnight % 1440) + 1440) % 1440
        if quietStartMinute < quietEndMinute {
            return m >= quietStartMinute && m < quietEndMinute
        }
        return m >= quietStartMinute || m < quietEndMinute
    }

    /// 这条 routine 通知是否该被扣下（免打扰时段内，或超每日预算）。
    func shouldHoldRoutine(sentToday: Int, minutesSinceMidnight: Int) -> Bool {
        if isQuietTime(minutesSinceMidnight: minutesSinceMidnight) { return true }
        return dailyRoutineLimit > 0 && sentToday >= dailyRoutineLimit
    }

    // MARK: - 摘要拼装

    struct DigestPlan: Equatable {
        var included: [String]
        var extraCount: Int
    }

    /// 摘要最多带 maxLines 行，其余折成 "+N" 计数（文案本地化在 store 侧）。
    static func digestPlan(lines: [String], maxLines: Int = 5) -> DigestPlan {
        guard lines.count > maxLines else {
            return DigestPlan(included: lines, extraCount: 0)
        }
        return DigestPlan(included: Array(lines.prefix(maxLines)),
                          extraCount: lines.count - maxLines)
    }

    // MARK: - 时间文本（设置 UI 与桥共用）

    static func minutesFromHHMM(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func hhmm(fromMinutes minutes: Int) -> String {
        let m = max(0, min(23 * 60 + 59, minutes))
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}
