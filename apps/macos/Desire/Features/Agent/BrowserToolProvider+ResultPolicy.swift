import Foundation
import os

/// 工具执行策略（v0.8.51 批 3）：**结果预算**与**超时分级**收口在一处。
///
/// - 结果预算：单工具结果默认上限 24k 字符，超出追加显式截断标记（不静默丢）；
///   读文件/文档类工具在表里声明更大的预算（readFile 等自带 60k 语义）。
/// - 超时：默认 120s 兜底；长任务型工具（自己立刻返回 job id 的、带自身等待
///   参数的）**不套超时**——否则会把"job 已受理"误判成失败。
///   WebKit 的 JS 求值无法真正取消：超时后由调用方放弃等待，工具本体在后台
///   跑完并记日志（不阻断回合）。
extension BrowserToolProvider {

    /// 默认超时（秒）。
    nonisolated static let toolTimeoutSeconds: Double = 120

    /// 不套超时的工具前缀/名字：长任务（立刻返回 job id）与自带等待参数的工具。
    static let noTimeoutTools: Set<String> = [
        "runCommand", "runBackgroundCommand", "startRecording",
        "researchBrief", "editTimeline", "editVideoPro", "downloadMedia",
        "downloadFile", "downloadVideoList", "downloadAllPageVideos",
        "wait", "waitFor", "waitForElement", "waitForSelector", "waitForText",
        "waitForDownload", "spawnSubagent", "crewDispatch", "watchBackgroundTasks",
    ]

    static func shouldTimeOut(_ tool: String) -> Bool {
        if noTimeoutTools.contains(tool) { return false }
        // 批量/导出族的名字里带 batch/export 的都算长任务。
        let lower = tool.lowercased()
        return !(lower.contains("batch") || lower.hasPrefix("export"))
    }

    /// 超限截断 + 显式标记：实现与测试在 Foundation-only 的 `ToolResultBudget`。
    static func applyResultBudget(_ result: String, tool: String) -> String {
        ToolResultBudget.apply(result, tool: tool)
    }

    /// 竞速超时：首个完成者胜；超时后放弃等待（工具本体在后台跑完只记日志）。
    static func withToolTimeout(_ tool: String, seconds: Double = toolTimeoutSeconds,
                                body: @escaping @MainActor () async -> String) async -> String {
        guard shouldTimeOut(tool) else { return await body() }
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }
        let gate = Gate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            Task { @MainActor in
                let value = await body()
                if gate.claim() {
                    continuation.resume(returning: value)
                } else {
                    Logger(subsystem: "me.siwi.Desire", category: "agent").info(
                        "tool \(tool, privacy: .public) finished after the timeout — result dropped")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if gate.claim() {
                    Logger(subsystem: "me.siwi.Desire", category: "agent").fault(
                        "tool \(tool, privacy: .public) timed out after \(Int(seconds), privacy: .public)s")
                    continuation.resume(returning: Self.fail(
                        "timed out after \(Int(seconds))s — use a job-based tool for long work"))
                }
            }
        }
    }
}
