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
/// （包装时刻起算——慢网关冷启动也在保护面内）。
///
/// **实现纪律（2026-11-16 两轮活体事故，独立最小复现定案）**：
/// ① 守望**必须用 GCD `asyncAfter` 自重排链**——`DispatchSourceTimer` 在
/// AsyncThrowingStream 消费挂起的进程形态里**不触发**（原因未明：同队列
/// asyncAfter 正常、独立程序里同款 timer source 正常）；`Task.sleep` 轮询
/// 更不行——每条活跃流常驻占一个协作线程，多流并发把协作池吃光（桥曾因
/// 此全端点饿死，sample 547 份栈都在 watchdog 的 sleep 循环上）。
/// ② 超窗后 `pump.cancel()`，但 **AsyncThrowingStream 被取消时 `next()`
/// 返回 nil 而不是抛 CancellationError**——timedOut 必须在"next() 返回
/// nil"分支里检测 expiry 标志补抛，否则超时被吞成"正常结束"（消费方以为
/// 模型答完了）。泵闭包对 holder 弱引用（holder 强持有 pump 句柄，强环
/// 会泄漏）；holder 的状态读写全程锁保护（泵与 GCD 链跨线程）。
nonisolated enum AgentStreamWatchdog {

    static var stallSeconds: TimeInterval {
        let raw = AppPrefs.defaults.double(forKey: "agentStreamStallSeconds")
        return raw >= 30 ? raw : 180
    }

    private static let tickInterval: TimeInterval = 5

    static func wrap(_ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
                     window: TimeInterval? = nil) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let window = window ?? stallSeconds
        Log.agent.info("stream watchdog: armed (window \(Int(window))s)")
        let holder = DeadlineHolder(window: window)
        return AsyncThrowingStream { continuation in
            // 守望：asyncAfter 自重排链（GCD 全局队列，不占 Swift 协作池）。
            func armWatch(_ depth: Int) {
                guard depth < 10_000 else { return }   // 数天上限，防御性
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + tickInterval) {
                    guard holder.shouldCancel() else {
                        guard !holder.isFinished else { return }
                        armWatch(depth + 1)
                        return
                    }
                    Log.agent.fault("stream watchdog: no event for \(Int(window))s — cancelling the stream")
                    holder.markExpired()
                    holder.cancelPump()
                }
            }
            armWatch(0)
            // 泵：消费内层流并转发（每个事件把超时线推后）。占一个协作线程
            // 是必要成本（await 事件），流结束即释放；闭包对 holder 弱引用。
            let pump = Task { [weak holder] in
                do {
                    var iterator = stream.makeAsyncIterator()
                    while let event = try await iterator.next() {
                        holder?.touch()
                        continuation.yield(event)
                    }
                    // next() 返回 nil：自然结束**或被本看门狗取消**——取消时
                    // AsyncThrowingStream 不抛错，expiry 标志在这里补抛。
                    if let expired = holder?.takeExpiredError() {
                        Log.agent.fault("stream watchdog: surfacing timedOut to the consumer")
                        continuation.finish(throwing: expired)
                        return
                    }
                    holder?.markFinished()
                    continuation.finish()
                } catch {
                    if let expired = holder?.takeExpiredError() {
                        continuation.finish(throwing: expired)
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            holder.setPump(pump)
            continuation.onTermination = { [weak holder] _ in
                holder?.teardown()
            }
        }
    }

    /// 状态（泵写、GCD 链读，锁保护；泵句柄强持有、闭包回指全弱）。
    private final class DeadlineHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var lastEvent: Date
        private let window: TimeInterval
        private var finished = false
        private var expiryPending = false
        private var pump: Task<Void, Never>?

        init(window: TimeInterval) {
            self.window = window
            self.lastEvent = Date()
        }

        func touch() {
            lock.lock()
            lastEvent = Date()
            lock.unlock()
        }

        /// 守望判定：流未结束且距最后事件超窗。
        func shouldCancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !finished && Date().timeIntervalSince(lastEvent) > window
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func markExpired() {
            lock.lock()
            expiryPending = true
            lock.unlock()
        }

        func markFinished() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        /// 泵结束/被取消时调用：到期触发的取消换回 timedOut，其余原样（nil）。
        func takeExpiredError() -> URLError? {
            lock.lock()
            defer { lock.unlock() }
            guard expiryPending else { return nil }
            expiryPending = false
            return URLError(.timedOut)
        }

        func setPump(_ pump: Task<Void, Never>) {
            lock.lock()
            self.pump = pump
            lock.unlock()
        }

        func cancelPump() {
            lock.lock()
            let task = pump
            lock.unlock()
            task?.cancel()
        }

        /// 流结束/消费方终止：停守望链、取消泵（幂等）。
        func teardown() {
            markFinished()
            cancelPump()
        }
    }
}
