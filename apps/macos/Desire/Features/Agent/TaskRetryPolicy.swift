import Foundation

/// 定时任务的单步重试策略（v0.8.81 批 6）：从全局默认与任务级覆盖解析出
/// 实际次数，退避仍是 30s → 60s → 120s。纯逻辑（Foundation-only），
/// 调度器只负责等待与重投。
nonisolated enum TaskRetryPolicy {
    static let maxRetries = 3
    static let defaultRetries = 1

    /// `taskValue` = 任务上的 `retryLimit`（nil = 跟随全局）；非法值钳到 0…3。
    static func resolvedLimit(taskValue: Int?, global: Int) -> Int {
        let raw = taskValue ?? global
        return min(max(raw, 0), maxRetries)
    }

    /// 第 `attempt` 次失败后等待的秒数：30, 60, 120…
    static func delaySeconds(afterAttempt attempt: Int) -> UInt64 {
        let exponent = max(0, min(attempt - 1, 6))
        return UInt64(30 * (1 << exponent))
    }
}
