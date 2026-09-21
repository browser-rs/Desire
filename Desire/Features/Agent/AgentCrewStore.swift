import Combine
import Foundation
import os
import WebKit

/// Tab Crew（0.3.1）：领队（用户对话的 Agent 会话）把任务拆成 N 个子
/// 任务，每个子任务在**自己的标签**上跑一个轻量 Agent 循环（工具面
/// 钉在该标签的 webview），完成后结果聚合回领队会话。
///
/// Worker 不是完整对话：单向"模型 → 工具 → 模型"循环，预算 8 次工具
/// 调用 / 10 轮，模型停止调用工具时视为产出最终报告。工具面走
/// BrowserToolProvider，但 worker 只暴露只读研究型工具子集。
@MainActor
final class AgentCrewStore: ObservableObject {
    static let shared = AgentCrewStore()

    /// 进行中的作业组（v1：全局一个活跃组）。
    @Published private(set) var crew: Crew?

    struct Crew: Identifiable {
        let id = UUID()
        var objective: String
        var tasks: [WorkerTask]
        var createdAt = Date()
        var finishedAt: Date?

        var completedCount: Int { tasks.filter { $0.state == .done }.count }
        var failedCount: Int { tasks.filter { $0.state == .failed }.count }
        var isSettled: Bool { tasks.allSatisfy { $0.state.isTerminal } }
    }

    final class WorkerTask: Identifiable {
        let id = UUID()
        let index: Int
        let instruction: String
        let url: String?
        let tabID: UUID?
        var state: State = .pending
        var result: String?
        var startedAt: Date?
        var finishedAt: Date?
        var task: Task<Void, Never>?

        enum State: String {
            case pending, running, done, failed, cancelled

            var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
        }

        init(index: Int, instruction: String, url: String?, tabID: UUID?) {
            self.index = index
            self.instruction = instruction
            self.url = url
            self.tabID = tabID
        }
    }

    /// 全部落定回调：领队会话注入，把聚合摘要送回领队消息流。
    var onCrewSettled: ((Crew) -> Void)?

    /// worker 允许的工具（只读研究子集——不给 click/fill/下载/写入）。
    private static let workerToolNames: Set<String> = [
        "getPageSnapshot", "getPageText", "getPageLinks", "findInPage", "extractTables",
    ]

    private init() {}

    // MARK: - Dispatch (crewDispatch tool)

    @discardableResult
    func dispatch(objective: String, tasks: [(url: String?, instruction: String)],
                  surface: BrowserToolSurface) -> String {
        guard crew == nil || crew?.isSettled == true else {
            return "A crew is already running. Use crewStatus to poll or crewCancel first."
        }
        guard !tasks.isEmpty else { return "No tasks provided" }
        guard tasks.count <= 6 else { return "At most 6 subtasks per crew" }
        guard let manager = surface.tabManager else { return "No tab manager" }

        let jsEnabled = surface.settings.isJavaScriptEnabled
        var workers: [WorkerTask] = []
        for (i, t) in tasks.enumerated() {
            // 每个子任务一个专属后台标签（不抢选中态）。
            manager.addTab(url: t.url, javaScriptEnabled: jsEnabled,
                           contentBlocker: surface.contentBlocker,
                           videoAdBlocker: surface.videoAdBlocker,
                           autoPlayPolicy: .never, newTabPosition: .end)
            let tab = manager.tabs.last
            workers.append(WorkerTask(index: i, instruction: t.instruction,
                                      url: t.url, tabID: tab?.id))
        }
        let c = Crew(objective: objective, tasks: workers)
        crew = c
        BridgeEventBus.shared.publish("crewStarted", [
            "objective": objective, "tasks": workers.count,
        ])

        // 串行起步（同一 LLM 端点的并发上限不可控；浏览侧仍是独立标签
        // 并行加载）。落定后 crew 清位，允许下一组。
        Task { [weak self] in
            for worker in c.tasks {
                guard let self, !Task.isCancelled else { return }
                await self.runWorker(worker, surface: surface)
            }
        }
        return """
        Crew dispatched: "\(objective)" with \(workers.count) subtask(s), each on its own tab.
        Use crewStatus to poll progress. Final reports aggregate when all settle.
        """
    }

    /// 单个 worker：单向流式循环，工具面钉在 worker 标签的 webview。
    private func runWorker(_ worker: WorkerTask, surface: BrowserToolSurface) async {
        guard let tabID = worker.tabID,
              let tab = surface.tabManager?.tabs.first(where: { $0.id == tabID }) else {
            worker.state = .failed
            worker.result = "worker tab vanished"
            worker.finishedAt = Date()
            return
        }
        worker.state = .running
        worker.startedAt = Date()

        let provider = BrowserToolProvider()
        let toolDefs = BrowserToolProvider.toolDefs.filter { Self.workerToolNames.contains($0.function.name) }
        let toolsNote = toolDefs.map(\.function.name).joined(separator: ", ")
        var transcript: [AgentMessage] = [
            AgentMessage(role: .system, content: """
            You are a focused web-research worker for the Desire browser.
            Complete the given subtask using the available tools
            (\(toolsNote)), then reply with a concise final report:
            key facts + source URLs. Budget: at most 8 tool calls.
            """),
            AgentMessage(role: .user, content: """
            Subtask: \(worker.instruction)
            Start from: \(tab.urlString)
            Navigate this tab when needed, read, then report.
            """),
        ]

        var calls = 0
        defer { worker.finishedAt = Date() }
        for _ in 0..<10 {
            // Cancelled (per-worker) workers must stop burning model calls —
            // the state flag is what cancel(taskIndex:) sets.
            if Task.isCancelled || worker.state == .cancelled {
                if worker.state != .cancelled { worker.state = .cancelled }
                return
            }
            // 单轮流式：聚合文本与工具调用。
            var text = ""
            var toolCalls: [AgentToolCall] = []
            do {
                // 走用户配置的 provider(routing/Ollama/cloud)——旧的
                // AgentService facade 写死云端,无 API key 的配置必然失败。
                for try await event in surface.agentPreference.provider.stream(messages: transcript, tools: toolDefs, prefs: surface.agentPreference) {
                    if worker.state == .cancelled { break }
                    switch event {
                    case .text(let chunk):
                        text += chunk
                    case .toolCall(let call):
                        toolCalls.append(call)
                    case .reasoning:
                        // 子任务不需要思考过程（结果里不带它）。
                        break
                    case .usage:
                        break
                    }
                }
            } catch {
                if worker.state != .cancelled {
                    worker.state = .failed
                    worker.result = "model error: \(error.localizedDescription)"
                }
                return
            }
            if !text.isEmpty {
                transcript.append(AgentMessage(role: .assistant, content: text, toolCalls: toolCalls.isEmpty ? nil : toolCalls))
            } else if !toolCalls.isEmpty {
                transcript.append(AgentMessage(role: .assistant, content: nil, toolCalls: toolCalls))
            }

            if toolCalls.isEmpty {
                // 无工具调用 = 最终报告。
                worker.state = .done
                worker.result = text.isEmpty ? "(empty report)" : text
                settleIfDone()
                return
            }
            for call in toolCalls {
                calls += 1
                guard calls <= 8 else {
                    worker.state = .failed
                    worker.result = "tool-call budget exhausted"
                    settleIfDone()
                    return
                }
                let result = await provider.execute(call, in: tab.browser.webView)
                transcript.append(AgentMessage(role: .tool, content: String(result.prefix(4000)),
                                               toolCallId: call.id, toolName: call.function.name))
            }
        }
        worker.state = .failed
        worker.result = "round budget exhausted"
        settleIfDone()
    }

    private func settleIfDone() {
        guard var c = crew, c.isSettled else { return }
        c.finishedAt = Date()
        crew = c
        BridgeEventBus.shared.publish("crewSettled", [
            "objective": c.objective,
            "done": c.completedCount,
            "failed": c.failedCount,
        ])
        onCrewSettled?(c)
    }

    // MARK: - Status / Cancel（crew 工具 + 桥共用）

    func statusReport() -> String {
        guard let c = crew else { return "No crew has been dispatched" }
        let lines = c.tasks.map { t -> String in
            var line = "[\(t.index)] \(t.state.rawValue.uppercased()) — \(t.instruction.prefix(70))"
            if let r = t.result { line += "\n    → \(r.prefix(600))" }
            return line
        }
        let head = "Crew \"\(c.objective)\": \(c.completedCount)/\(c.tasks.count) done" +
            (c.failedCount > 0 ? ", \(c.failedCount) failed" : "") +
            (c.isSettled ? " (settled — aggregate now)" : "")
        return head + "\n" + lines.joined(separator: "\n")
    }

    @discardableResult
    func cancel(taskIndex: Int) -> String {
        guard let c = crew, c.tasks.indices.contains(taskIndex) else { return "No such task index" }
        let t = c.tasks[taskIndex]
        t.task?.cancel()
        t.state = .cancelled
        t.finishedAt = Date()
        settleIfDone()
        return "Cancelled subtask \(taskIndex)"
    }

    func cancelAll() {
        guard let c = crew else { return }
        for t in c.tasks where !t.state.isTerminal {
            t.task?.cancel()
            t.state = .cancelled
        }
        settleIfDone()
    }
}
