import Foundation

/// 主线程心跳的共享时间戳（v0.8.49 批 2）。独立成 Foundation-only 文件是为了
/// 进 `tests/run.sh`（RuntimeHealthMonitor 依赖 AppKit，进不了纯逻辑 harness）。
///
/// **睡眠感知**（v0.8.76 批 1）：心跳年龄此前用墙钟计算——机器睡眠时墙钟照走，
/// 于是系统每次维护性短暂唤醒（DarkWake），watchdog 都看到"心跳停了几十秒到
/// 几小时"，报一次"主线程停滞"并 fork `sample` 采样。实测安装版 34 次停滞记录
/// 里 32 次落在 DarkWake 窗口内，没有一次是真实卡顿。
///
/// 现在用两种单调时钟：
/// - `systemUptime`（= mach_absolute_time，**不含睡眠**）——算心跳年龄；
/// - `mach_continuous_time`（**含睡眠**）——与前者之差只会在系统睡眠时增长，
///   据此在 watchdog 自己的线程上检测"期间睡过"，不依赖主线程投递的唤醒通知
///   （主线程真卡死时通知根本不会被处理）。
///
/// 检测到睡眠 → 重置计时并进入冷却（默认 30 秒单调时间）。冷却跨睡眠：DarkWake
/// 只醒十几秒，下次唤醒时又检测到新的睡眠、再次冷却——睡眠期间永不误报。
///
/// 取舍：入睡瞬间主线程恰好已卡过阈值、且 watchdog 还没来得及看到——这次卡顿
/// 会被睡醒重置吞掉。若主线程是真卡死，唤醒后心跳不会恢复，冷却结束照报；只是
/// 极小概率漏掉"睡前那一小段卡顿"，换来睡眠期零误报。
nonisolated final class HealthClock: @unchecked Sendable {
    static let shared = HealthClock()

    /// 一次时钟读数。可注入——单测据此模拟"卡住"与"睡眠"。
    struct Reading: Equatable, Sendable {
        /// 不含睡眠的单调秒。
        var mono: Double
        /// 含睡眠的单调秒。
        var cont: Double

        static func now() -> Reading {
            Reading(mono: ProcessInfo.processInfo.systemUptime, cont: continuousSeconds)
        }

        /// mach_continuous_time 换算成秒（时基每次现查，不缓存）。
        static var continuousSeconds: Double {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1e9
        }
    }

    /// 心跳超过这个单调秒数没来 = 停滞。
    static let stallThreshold: TimeInterval = 10
    /// 检测到睡眠后的冷却时长（单调秒）。
    static let wakeCooldown: TimeInterval = 30
    /// 两次 tick 之间时钟漂移超过这个秒数即判定"期间睡过"。两种时钟的读取之间
    /// 只差微秒级；DarkWake 间隔的睡眠至少数秒。
    static let sleepDriftThreshold: TimeInterval = 1.0

    /// watchdog 一次 tick 的结论。
    enum Verdict: Equatable, Sendable {
        /// 心跳正常。
        case healthy
        /// 期间系统睡过：计时已重置、已进入冷却——不报。
        case wokeFromSleep
        /// 唤醒后的冷却期内——不报。
        case coolingDown
        /// 心跳停滞。`isNew` = 本轮停滞第一次被发现（应取证）；
        /// 之后同一轮的 tick 仍报停滞但 `isNew == false`（不重复取证）。
        case stalled(seconds: Double, isNew: Bool)
    }

    private let lock = NSLock()
    /// 最近一次心跳的单调时刻。
    private var ackMono: Double
    /// 上次见到的时钟漂移（cont − mono）。只会在系统睡眠时增大。
    private var driftAtLastTick: Double
    /// 冷却截止的单调时刻。
    private var suppressUntilMono: Double
    private var stallClaimed = false
    /// 进程启动以来观测到的睡眠次数（诊断用）。
    private var sleepCount = 0

    init(reading: Reading = .now()) {
        ackMono = reading.mono
        driftAtLastTick = reading.cont - reading.mono
        suppressUntilMono = 0
    }

    /// 主线程心跳：重置计时，并允许下一轮停滞重新取证。
    func ack(reading: Reading = .now()) {
        lock.lock()
        defer { lock.unlock() }
        ackMono = reading.mono
        stallClaimed = false
    }

    /// 距最近一次心跳过了多少单调秒（不含睡眠）。
    func idleSeconds(reading: Reading = .now()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return max(0, reading.mono - ackMono)
    }

    var observedSleepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepCount
    }

    /// watchdog 每 tick 调一次。先判睡眠，再判冷却，最后才判停滞。
    func watchdogTick(reading: Reading = .now(),
                      threshold: TimeInterval = stallThreshold,
                      cooldown: TimeInterval = wakeCooldown,
                      sleepDrift: TimeInterval = sleepDriftThreshold) -> Verdict {
        lock.lock()
        defer { lock.unlock() }
        let drift = reading.cont - reading.mono
        defer { driftAtLastTick = drift }

        if drift - driftAtLastTick > sleepDrift {
            // 期间系统睡过：主线程没跳是应该的。重置计时、冷却、清掉上一轮的
            // 停滞标记（那是睡前的事了）。
            sleepCount += 1
            ackMono = reading.mono
            suppressUntilMono = reading.mono + cooldown
            stallClaimed = false
            return .wokeFromSleep
        }
        if reading.mono < suppressUntilMono { return .coolingDown }
        let idle = reading.mono - ackMono
        guard idle > threshold else { return .healthy }
        if stallClaimed { return .stalled(seconds: idle, isNew: false) }
        stallClaimed = true
        return .stalled(seconds: idle, isNew: true)
    }
}
