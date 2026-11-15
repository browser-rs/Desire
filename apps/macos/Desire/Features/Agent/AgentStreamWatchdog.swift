import Foundation
import os

/// **流式停摆看门狗**（2026-11-15）：模型流可能"永远不来下一个事件"——
/// 上游黑洞、网关只发 SSE keepalive 注释行（`for try await line` 循环里
/// `guard line.hasPrefix("data: ")` 直接跳过，不产生任何事件）……此前回合
/// 就挂在 "Thinking…" 上，只能强杀进程。包装层以"最后一个事件"计时，超窗
/// 即向消费方抛 `URLError(.timedOut)`——正好落进既有的瞬态错误/failover
/// 重试路径，用户看到的是换档案重试或明确报错，而不是永久挂起。
///
/// 超窗必须宽于深度思考型模型的最长合法静默（默认 180s；UserDefaults
/// `agentStreamStallSeconds` 可调，下限 30s）。首事件延迟同样受窗约束
/// （包装时刻起算）——慢网关冷启动也在保护面内。
nonisolated enum AgentStreamWatchdog {

    static var stallSeconds: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: "agentStreamStallSeconds")
        return raw >= 30 ? raw : 180
    }

    static func wrap(_ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
                     window: TimeInterval? = nil) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let window = window ?? stallSeconds
        Log.agent.info("stream watchdog: armed (window \(Int(window))s)")
        let deadline = DeadlineHolder(window: window)
        return AsyncThrowingStream { continuation in
            // 泵：消费内层流并转发（每个事件把超时线推后）。
            let pump = Task {
                do {
                    var iterator = stream.makeAsyncIterator()
                    while let event = try await iterator.next() {
                        deadline.touch()
                        continuation.yield(event)
                    }
                    deadline.finish()
                    continuation.finish()
                } catch {
                    // 看门狗到期主动取消泵时，CancellationError 要换回
                    // timedOut——否则消费方把"停摆"误判成"用户打断"。
                    if let expired = deadline.takeExpiredError() {
                        continuation.finish(throwing: expired)
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            // 守望：每 5s 查一次最后事件时间。
            let warden = Task {
                while !deadline.isFinished {
                    try? await Task.sleep(for: .seconds(5))
                    if deadline.isFinished { return }
                    if deadline.expired() {
                        Log.agent.fault("stream watchdog: no event for \(Int(window))s — cancelling the stream")
                        deadline.markExpired()
                        pump.cancel()
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                warden.cancel()
            }
        }
    }

    /// 最后事件时间戳（泵写、守望读）+ 到期标志，锁保护跨 Task 访问。
    private final class DeadlineHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var lastEvent: Date
        private var window: TimeInterval
        private var finished = false
        private var expiryPending = false

        init(window: TimeInterval) {
            self.window = window
            self.lastEvent = Date()
        }

        func touch() {
            lock.lock()
            lastEvent = Date()
            lock.unlock()
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func finish() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        func expired() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !finished && Date().timeIntervalSince(lastEvent) > window
        }

        func markExpired() {
            lock.lock()
            expiryPending = true
            lock.unlock()
        }

        /// 泵被取消时调用：到期触发的取消换回 timedOut，其余原样（nil）。
        func takeExpiredError() -> URLError? {
            lock.lock()
            defer { lock.unlock() }
            guard expiryPending else { return nil }
            expiryPending = false
            return URLError(.timedOut)
        }
    }
}
