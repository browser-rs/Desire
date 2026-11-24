import AppKit
import Foundation
import os

/// 主线程健康监测（v0.8.49 批 2）。
///
/// 背景：主 actor 被 ObjC 异常钉死后，应用"看起来正常"——窗口仍渲染、事件循环
/// 还在，但所有 `@MainActor` 任务只排队不执行、桥全超时、**没有崩溃报告**。
/// 本轮开发中遇到过两次，都是靠 `sample` + lldb 手工定位。
///
/// 机制：
/// - 主线程每 2s 打一次心跳（`Timer` 在主 runloop；主线程一旦卡住心跳就停）。
/// - 后台 watchdog 每 5s 读一次心跳时间（**全在后台队列**，不做任何主 actor
///   hop——主线程死了 hop 永远不会执行）：超过 10s 没心跳 = 停滞 →
///   fault 日志 + `health/last-stall.json`，并尝试 `/usr/bin/sample` 抓栈
///   （Hardened Runtime 下可能失败，失败只记 sampled=false）。
/// - **心跳年龄按不含睡眠的单调时钟计算**（v0.8.76 批 1，判定在 `HealthClock`）：
///   此前用墙钟，机器睡眠时系统每次维护性短暂唤醒都会误报一次停滞。
/// - 只取证，不尝试自愈（RunLoop 已坏，进程内救不回来）。
@MainActor
final class RuntimeHealthMonitor {
    static let shared = RuntimeHealthMonitor()

    private static let beatInterval: TimeInterval = 2
    private nonisolated static let stallThreshold: TimeInterval = 10

    private var heartbeat: Timer?
    private var watchdog: DispatchSourceTimer?

    nonisolated static var directory: URL {
        let base = StorageRoot.directory
            .appendingPathComponent("health", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static var lastStallFile: URL { directory.appendingPathComponent("last-stall.json") }
    /// 上一个进程留下的停滞记录（启动时由 last-stall.json 挪过来）。
    nonisolated static var previousStallFile: URL { directory.appendingPathComponent("previous-stall.json") }

    nonisolated struct StallRecord: Codable {
        var startedAt: Date
        var seconds: Double
        var sampled: Bool
        var samplePath: String?
        /// 计时口径标记。nil = v0.8.76 之前写的记录——那时心跳年龄用墙钟算，
        /// 实测绝大多数是机器睡眠的误报，不可信，读取侧一律忽略。
        var clock: String?
        /// 写下这条记录的构建来源（`BuildSource.rawValue`）；nil = 旧记录。
        var buildSource: String?

        static let monotonicClockTag = "monotonic-v2"
    }

    /// 最近一次**可信**的停滞记录，以及它属于哪次运行。
    ///
    /// 可信 = 新口径（不含睡眠的单调时钟）且与当前实例同源。旧口径记录（睡眠
    /// 误报）和其他构建来源写入的记录都不返回。
    ///
    /// `isPreviousRun`：上一进程留下的记录。进程启动时会把 last-stall.json 挪到
    /// previous-stall.json——"上次运行的停滞"只在下一个进程里展示一次。此前那份
    /// 记录永不过期，哪怕是几天前的一次真实卡顿，也会在之后的每次启动里被当成
    /// 当前问题。
    nonisolated static func lastStall() -> (record: StallRecord, isPreviousRun: Bool)? {
        if let record = trustedStall(in: lastStallFile) { return (record, false) }
        if let record = trustedStall(in: previousStallFile) { return (record, true) }
        return nil
    }

    private nonisolated static func trustedStall(in file: URL) -> StallRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let record = try? JSONDecoder().decode(StallRecord.self, from: data) else { return nil }
        guard record.clock == StallRecord.monotonicClockTag else { return nil }
        guard record.buildSource == BuildSource.current.rawValue else { return nil }
        return record
    }

    /// 启动时把上一进程的记录归档（重复调用幂等）。
    private nonisolated static func archivePreviousRunStall() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: lastStallFile.path) else { return }
        try? fm.removeItem(at: previousStallFile)
        try? fm.moveItem(at: lastStallFile, to: previousStallFile)
    }

    /// 数据面汇总（诊断行 / GET /diag/health 用）。@MainActor 实例方法——
    /// NSApp.isActive 只能主线程读（v0.8.62 零警告闸修正）。
    func healthSummary(preference: AgentPreferenceStore? = nil) -> [String: Any] {
        var out: [String: Any] = [
            // 应用前台激活态（v0.8.62 批 4）：false = 后台实例——浏览器端点
            // （navigate 等）会静默失效（CI 教训的本地同源），测试与值守的
            // 浏览器类动作前先看这个字段。
            "appActive": NSApp.isActive,
            // 构建来源与睡眠感知（v0.8.76 批 1）：诊断数据分源；观测到的睡眠次数
            // 是"停滞记录是否可信"的旁证。
            "buildSource": BuildSource.current.rawValue,
            "observedSleepCount": HealthClock.shared.observedSleepCount,
        ]
        if let stall = Self.lastStall() {
            out["lastStall"] = [
                "startedAt": ISO8601DateFormatter().string(from: stall.record.startedAt),
                "seconds": stall.record.seconds,
                "sampled": stall.record.sampled,
                "samplePath": stall.record.samplePath ?? "",
                "previousRun": stall.isPreviousRun,
            ] as [String: Any]
        }
        let pool = CooperativePool.stats()
        if let p50 = pool.p50 { out["poolP50ms"] = Int(p50 * 1000) }
        if let p95 = pool.p95 { out["poolP95ms"] = Int(p95 * 1000) }
        out["poolSamples"] = pool.sampleCount

        // **模型校准段**（v0.8.62 批 4 增强）：每模型的窗口 tokens / 校准
        // 样本数 / EMA 字符-令牌比 / 当前生效字符预算——token 真值化是否在
        // 干活一目了然。override 生效时标注。
        if let preference {
            var calibrations: [[String: Any]] = []
            for (model, entry) in preference.modelCalibration.sorted(by: { $0.key < $1.key }) {
                // 窗口真值 = 当前档案显式设置（猜表已移除，v0.8.70 事故）；
                // 非当前模型的行窗口未知 → nil（budgetChars 回退 160k 默认）。
                let window = preference.activeProfile?.contextWindowTokens
                let budget = TokenCalibration.budgetChars(windowTokens: window, calibration: entry)
                calibrations.append([
                    "model": model,
                    "windowTokens": window as Any,
                    "samples": entry.samples,
                    "ratio": (entry.ratio * 100).rounded() / 100,
                    "budgetChars": budget,
                    "trusted": entry.samples >= TokenCalibration.minSamples,
                ])
            }
            if let active = preference.activeProfile {
                // 当前生效预算（会话内的 compactionBudgetOverride 在会话侧，
                // 诊断端点不反映 per-session 态——显示全局换算值）。
                out["calibrationBudgetChars"] = preference.calibratedBudgetChars(
                    forModel: active.model, profile: active)
                out["activeModel"] = active.model
            }
            out["calibrations"] = calibrations
        }
        return out
    }

    func start() {
        guard watchdog == nil else { return }
        Self.archivePreviousRunStall()
        HealthClock.shared.ack()
        CooperativePool.startProbe()
        // **common mode**（v0.8.68 体检发现）：scheduledTimer 默认挂 default
        // mode——模态弹窗（runModal）/菜单跟踪的嵌套事件循环里不触发，主线程
        // 实际活着却被 watchdog 误判成 26.5s 停滞（现场：样本栈
        // RunCurrentEventLoopInMode + 主线程全程 idle）。common mode 在这些
        // 嵌套循环里也触发，"心跳=主线程活着"的语义才成立。
        heartbeat = Timer(timeInterval: Self.beatInterval, repeats: true) { _ in
            HealthClock.shared.ack()
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        let queue = DispatchQueue(label: "me.siwi.Desire.health", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.stallThreshold, repeating: 5)
        timer.setEventHandler { Self.watchdogTick() }
        timer.resume()
        watchdog = timer
        // 诊断文件清理（v0.8.76 批 1）：启动后延迟跑，不占启动路径。
        DiagnosticGC.scheduleAll(directories: [Self.directory, MetricsManager.diagnosticsDirectory])
        Log.app.info("runtime health monitor started")
    }

    /// 后台线程：只读 HealthClock + 写文件/抓栈，**不做主 actor hop**。
    /// 睡眠与唤醒冷却的判定在 HealthClock 内（同样不依赖主线程）。
    private nonisolated static func watchdogTick() {
        guard case .stalled(let seconds, let isNew) = HealthClock.shared.watchdogTick(),
              isNew else { return }
        recordStall(seconds: seconds)
    }

    private nonisolated static func recordStall(seconds: Double) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let sampleURL = directory.appendingPathComponent("stall-\(stamp).txt")
        var sampled = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(pid)", "2", "-file", sampleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
            sampled = process.terminationStatus == 0
        }
        let record = StallRecord(startedAt: Date().addingTimeInterval(-seconds),
                                 seconds: seconds, sampled: sampled,
                                 samplePath: sampled ? sampleURL.path : nil,
                                 clock: StallRecord.monotonicClockTag,
                                 buildSource: BuildSource.current.rawValue)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: lastStallFile, options: .atomic)
        }
        Logger(subsystem: "me.siwi.Desire", category: "health").fault(
            "runtime health: main thread stalled for \(seconds, format: .fixed(precision: 1), privacy: .public)s (sample=\(sampled, privacy: .public))")
    }
}

/// **协作线程池水位观测**（v0.8.61）：协作池被长占时全局 async 任务饿死
/// （0.8.58 DiskStoreWriter / 0.8.60 watchdog 两案），此前只能靠 sample 抓
/// 栈事后取证。探针每 30s 派一个 utility detached 任务，"派发→执行"的延迟
/// 就是协作池的排队水位；滑动窗口（24 样本 = 12 分钟）取 p50/p95。p95 超
/// 2s fault 一条（10 分钟节流）——协作池饿死从此可看见。
nonisolated enum CooperativePool {

    /// 纯计算：排序样本取分位（空样本返回 nil）。进 tests/run.sh。
    static func percentile(_ samples: [Double], _ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let idx = min(sorted.count - 1,
                      max(0, Int((Double(sorted.count) * fraction).rounded(.down))))
        return sorted[idx]
    }

    private static let lock = NSLock()
    private static var samples: [Double] = []
    private static var lastFaultAt: Date = .distantPast
    private static var probeStarted = false

    static func startProbe() {
        lock.lock()
        if probeStarted {
            lock.unlock()
            return
        }
        probeStarted = true
        lock.unlock()
        schedule()
    }

    private static func schedule() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            measure()
            schedule()
        }
    }

    /// 探针本体：detached 任务的**首行时间戳 - 派发时刻** = 协作池排队延迟。
    /// （utility QoS 与业务后台任务同池——它慢就代表池在积压。）
    private static func measure() {
        let dispatched = Date()
        Task.detached(priority: .utility) {
            let latency = Date().timeIntervalSince(dispatched)
            record(latency)
        }
    }

    private static func record(_ latency: Double) {
        var shouldFault = false
        var p95: Double = 0
        lock.lock()
        samples.append(latency)
        if samples.count > 24 { samples.removeFirst(samples.count - 24) }
        if let q95 = percentile(samples, 0.95), samples.count >= 4 {
            p95 = q95
            if q95 > 2.0, Date().timeIntervalSince(lastFaultAt) > 600 {
                lastFaultAt = Date()
                shouldFault = true
            }
        }
        lock.unlock()
        if shouldFault {
            Logger(subsystem: "me.siwi.Desire", category: "health").fault(
                "runtime health: cooperative pool backed up — p95 scheduling latency \(String(format: "%.2f", p95), privacy: .public)s")
        }
    }

    /// 数据面（Doctor / 诊断端点）。
    static func stats() -> (p50: Double?, p95: Double?, sampleCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (percentile(samples, 0.5), percentile(samples, 0.95), samples.count)
    }
}
