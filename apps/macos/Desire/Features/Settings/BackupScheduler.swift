import Foundation
import os

/// 自动备份调度（v0.8.19 替人干活 18）：每日/每周 → 指定目录（默认备份
/// 目录）+ 轮转保留最近 N 份。 UserDefaults："backup.schedule"（off/daily/
/// weekly）、"backup.scheduleHour"（0-23，默认 9）、"backup.keep"（默认 5）。
/// Timer 每小时醒来核对"今天该跑且还没跑"（App 重启错过的当天备份会补跑）。
@MainActor
enum BackupScheduler {

    private static let log = Log.app

    enum Schedule: String {
        case off, daily, weekly
    }

    static var schedule: Schedule {
        Schedule(rawValue: UserDefaults.standard.string(forKey: "backup.schedule") ?? "") ?? .off
    }

    static func setSchedule(_ value: Schedule) {
        UserDefaults.standard.set(value.rawValue, forKey: "backup.schedule")
        UserDefaults.standard.set(dayStamp(Date()), forKey: "backup.lastCheck")
        start()
    }

    static var keepCount: Int {
        let raw = UserDefaults.standard.integer(forKey: "backup.keep")
        return (1...30).contains(raw) ? raw : 5
    }

    /// 启动挂钩（AppState.init）：每小时 tick 一次。
    nonisolated static func start() {
        Task { @MainActor in
            tick()
            for await _ in Clock.every(hours: 1) {
                tick()
            }
        }
    }

    /// 到点判定：调度开 + 当前小时 == 设定小时 + 今天还没跑（weekly 另要
    /// 周一）。补跑语义：重启跳过的当天备份会在当天设定小时后的任一 tick 补上。
    static func tick(now: Date = Date()) {
        let schedule = schedule
        guard schedule != .off else { return }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let scheduleHour = UserDefaults.standard.object(forKey: "backup.scheduleHour")
            as? Int ?? 9
        guard hour == max(0, min(23, scheduleHour)) else { return }
        if schedule == .weekly, calendar.component(.weekday, from: now) != 2 { return }   // 周一
        let stamp = dayStamp(now)
        guard UserDefaults.standard.string(forKey: "backup.lastRun") != stamp else { return }
        UserDefaults.standard.set(stamp, forKey: "backup.lastRun")
        run()
    }

    /// 跑一次 + 轮转。失败只记日志（下次 tick 当天还会补——lastRun 已置位，
    /// 失败当天不重试，避免坏盘循环；次日自然再试）。
    @discardableResult
    static func run() -> URL? {
        do {
            let result = try BackupService.export(toDirectory: BackupService.defaultDirectory)
            rotate(directory: BackupService.defaultDirectory)
            ProactiveNotificationStore.shared.deliver(
                title: String(localized: "Scheduled backup finished"),
                body: String(localized: "\(result.counts.values.reduce(0, +)) item(s) → \(result.url.lastPathComponent)"),
                tier: .routine)
            log.info("scheduled backup: \(result.url.lastPathComponent, privacy: .public)")
            return result.url
        } catch {
            log.error("scheduled backup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 轮转：只删本调度产生的 `desire-backup-*.json`（手动导出的同名前缀
    /// 共享——保留最近 keepCount 份，其余删除）。
    static func rotate(directory: URL, keep: Int? = nil) {
        let keep = keep ?? keepCount
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("desire-backup-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // 新在前（文件名含时间戳）
        for old in backups.dropFirst(max(1, keep)) {
            try? fm.removeItem(at: old)
        }
    }

    nonisolated static func dayStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// 极简周期 Clock（小时级够用；Swift Clock API 没有现成"每 N 小时"）。
@MainActor
enum Clock {
    static func every(hours: Int) -> AsyncStream<Void> {
        AsyncStream { continuation in
            Task {
                while true {
                    try? await Task.sleep(for: .seconds(Double(hours) * 3600))
                    continuation.yield(())
                }
            }
        }
    }
}
