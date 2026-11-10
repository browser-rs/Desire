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
/// - 只取证，不尝试自愈（RunLoop 已坏，进程内救不回来）。
@MainActor
final class RuntimeHealthMonitor {
    static let shared = RuntimeHealthMonitor()

    private static let beatInterval: TimeInterval = 2
    private nonisolated static let stallThreshold: TimeInterval = 10

    private var heartbeat: Timer?
    private var watchdog: DispatchSourceTimer?

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Desire/health", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static var lastStallFile: URL { directory.appendingPathComponent("last-stall.json") }

    nonisolated struct StallRecord: Codable {
        var startedAt: Date
        var seconds: Double
        var sampled: Bool
        var samplePath: String?
    }

    nonisolated static func lastStall() -> StallRecord? {
        guard let data = try? Data(contentsOf: lastStallFile) else { return nil }
        return try? JSONDecoder().decode(StallRecord.self, from: data)
    }

    func start() {
        guard watchdog == nil else { return }
        HealthClock.shared.ack()
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.beatInterval, repeats: true) { _ in
            HealthClock.shared.ack()
        }
        let queue = DispatchQueue(label: "me.siwi.Desire.health", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.stallThreshold, repeating: 5)
        timer.setEventHandler { Self.watchdogTick() }
        timer.resume()
        watchdog = timer
        Log.app.info("runtime health monitor started")
    }

    /// 后台线程：只读 HealthClock + 写文件/抓栈，**不做主 actor hop**。
    private nonisolated static func watchdogTick() {
        let idle = Date().timeIntervalSince1970 - HealthClock.shared.lastAck()
        guard idle > stallThreshold, HealthClock.shared.claimStallRecord() else { return }
        recordStall(seconds: idle)
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
                                 samplePath: sampled ? sampleURL.path : nil)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: lastStallFile, options: .atomic)
        }
        Logger(subsystem: "me.siwi.Desire", category: "health").fault(
            "runtime health: main thread stalled for \(seconds, format: .fixed(precision: 1), privacy: .public)s (sample=\(sampled, privacy: .public))")
    }
}
