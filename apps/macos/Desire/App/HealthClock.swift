import Foundation

/// 主线程心跳的共享时间戳（v0.8.49 批 2）。独立成 Foundation-only 文件是为了
/// 进 `tests/run.sh`（RuntimeHealthMonitor 依赖 AppKit，进不了纯逻辑 harness）。
nonisolated final class HealthClock: @unchecked Sendable {
    static let shared = HealthClock()
    private let lock = NSLock()
    private var ackAt: TimeInterval = Date().timeIntervalSince1970
    private var stallClaimed = false

    func ack() {
        lock.lock()
        ackAt = Date().timeIntervalSince1970
        stallClaimed = false
        lock.unlock()
    }

    func lastAck() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return ackAt
    }

    /// 本次停滞只记一次：返回 true = 由调用方写证据。
    func claimStallRecord() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stallClaimed { return false }
        stallClaimed = true
        return true
    }
}
