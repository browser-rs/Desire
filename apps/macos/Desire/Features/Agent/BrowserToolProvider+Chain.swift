import Foundation
import WebKit

/// 工具链执行（v0.8.51 批 2）：把多个工具**一次调用**串起来跑。
///
/// - 严格顺序执行（副作用步骤绝不并行）；
/// - 每步都走 `execute`（与普通工具调用同一条路径：标签租约、动作后核验、
///   观测缓存失效都照常生效）；
/// - 结果摘要见 `ToolChainCore.summarize`；提前停下时整体以 `Error:` 开头；
/// - `background: true` → 进 Jobs 台账，立刻返回 job id（长任务约定）。
extension BrowserToolProvider {

    func runToolChain(_ args: [String: Any], in webView: WKWebView) async -> String {
        // 嵌套守卫：子调用里我们注入 __chainDepth = 1，链里的 runToolChain 只
        // 需要看这个值就能拒绝——不依赖可变状态。
        let depth = args["__chainDepth"] as? Int ?? 0
        guard depth == 0 else {
            return Self.fail("runToolChain cannot be nested inside another chain")
        }
        let steps = ToolChainCore.parseSteps(args["steps"])
        guard !steps.isEmpty else {
            return Self.fail("steps required: an array of {tool, args}")
        }
        guard steps.count <= ToolChainCore.maxSteps else {
            return Self.fail("too many steps (max \(ToolChainCore.maxSteps))")
        }
        let onError = (args["onError"] as? String ?? "stop").lowercased() == "continue"
            ? "continue" : "stop"
        if (args["background"] as? Bool) == true {
            return runChainInBackground(steps: steps, onError: onError, in: webView)
        }
        let (text, _) = await executeChain(steps: steps, onError: onError, in: webView, progress: nil)
        return text
    }

    private func executeChain(steps: [ToolChainCore.Step], onError: String,
                              in webView: WKWebView,
                              progress: ((Int, Int, String) -> Void)?)
        async -> (String, [ToolChainCore.Outcome]) {
        var outcomes: [ToolChainCore.Outcome] = []
        var results: [String] = []
        var stopped = false

        for (index, step) in steps.enumerated() {
            // 回合被取消：链就地收尾（不再启动后续步骤）。
            if Task.isCancelled {
                let message = "Error: cancelled by user"
                outcomes.append(.init(index: index + 1, tool: step.tool, result: message,
                                      seconds: 0, failed: true))
                results.append(message)
                stopped = true
                break
            }
            if step.tool == "runToolChain" {
                let message = "Error: nested chains are not allowed"
                outcomes.append(.init(index: index + 1, tool: step.tool, result: message,
                                      seconds: 0, failed: true))
                results.append(message)
                if onError == "stop" { stopped = true; break }
                continue
            }
            let substituted = ToolChainCore.substitute(args: step.args, results: results)
            var envelope = substituted
            envelope["__chainDepth"] = 1
            guard let data = try? JSONSerialization.data(withJSONObject: envelope),
                  let json = String(data: data, encoding: .utf8) else {
                let message = "Error: step \(index + 1) arguments are not JSON-encodable"
                outcomes.append(.init(index: index + 1, tool: step.tool, result: message,
                                      seconds: 0, failed: true))
                results.append(message)
                if onError == "stop" { stopped = true; break }
                continue
            }
            let call = AgentToolCall(
                id: "chain-\(index + 1)-\(UUID().uuidString.prefix(6))",
                type: "function",
                function: AgentToolFunction(name: step.tool, arguments: json))
            let started = Date()
            let result = await execute(call, in: webView)
            let seconds = Date().timeIntervalSince(started)
            let failed = ToolChainCore.isFailure(result)
            outcomes.append(.init(index: index + 1, tool: step.tool, result: result,
                                  seconds: seconds, failed: failed))
            results.append(result)
            progress?(index + 1, steps.count, step.tool)
            if failed, onError == "stop" { stopped = true; break }
        }

        let summary = ToolChainCore.overallPrefix(stopped: stopped)
            + ToolChainCore.summarize(outcomes: outcomes, onError: onError, stopped: stopped)
        return (summary, outcomes)
    }

    /// 后台链（长任务约定）：立刻返回 job id，完成后会话备注 + 通知。
    private func runChainInBackground(steps: [ToolChainCore.Step], onError: String,
                                      in webView: WKWebView) -> String {
        let jobID = JobStore.shared.start(
            title: String(localized: "Tool chain"),
            kind: .agent,
            detail: "\(steps.count) step(s)",
            source: "toolChain")
        let provider = self
        Task { @MainActor in
            let (text, outcomes) = await provider.executeChain(
                steps: steps, onError: onError, in: webView) { done, total, tool in
                    JobStore.shared.update(jobID,
                                           detail: "\(done)/\(total): \(tool)",
                                           progress: Double(done) / Double(max(1, total)))
                }
            let failed = outcomes.filter(\.failed).count
            JobStore.shared.finish(jobID,
                                   state: failed == 0 ? .done : .failed,
                                   detail: "\(outcomes.count - failed)/\(outcomes.count) ok",
                                   receipt: text,
                                   error: failed == 0 ? nil : "\(failed) step(s) failed")
            AgentScheduler.shared.deliveryTarget?.appendExternalNote(
                "Tool chain finished: \(text)")
            ProactiveNotificationStore.shared.deliver(
                title: String(localized: "Tool chain finished"),
                body: String(localized: "Open the Jobs panel to see the results."),
                tier: .routine)
        }
        return "Tool chain started as job \(jobID.uuidString). \(steps.count) step(s) run in order; check backgroundTaskStatus or the Jobs panel."
    }
}
