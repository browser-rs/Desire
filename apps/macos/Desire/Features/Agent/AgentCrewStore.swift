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

    /// 本次 crew 的 token 用量累计（worker 跑在各自标签页里，此前**无处记账**）。
    /// 落定时由会话写成一条带 token 字段的系统备注 —— 成本与统计才把 crew 算进去。
    struct TokenUsage {
        var promptTokens = 0
        var completionTokens = 0
        /// worker 实际用的模型 id（取第一个上报的；混合模型时留空 —— 归"子代理"桶）。
        var model: String?
        var total: Int { promptTokens + completionTokens }
        var isEmpty: Bool { total == 0 }
    }
    private(set) var usage = TokenUsage()

    /// 会话侧把用量落成系统备注后调用（清零，下一次 crew 从零累计）。
    func resetUsage() { usage = TokenUsage() }

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
        /// 运行观察面（v0.7.22）：当前步骤的一句话描述 + 工具调用计数
        /// （"思考中（第 2 轮）"/"调用 extractTables"/"撰写报告"）。
        var currentStep: String?
        var toolCallCount: Int = 0
        /// 逐 worker 用量（v0.7.27）：模型与 token——面板/桥按 worker 展示成本，
        /// 不再只有一个 crew 总量。模型取第一次上报（worker 不换模型）。
        var model: String?
        var promptTokens = 0
        var completionTokens = 0
        var totalTokens: Int { promptTokens + completionTokens }

        enum State: String {
            case pending, running, done, failed, cancelled

            var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
        }

        /// 跨窗 v2（v0.8.8）：目标窗口会话（nil = 本窗标签模式）。窗口模式下
        /// tabID 为空、worker 跑在目标窗口自己的 Agent 会话里（独立工具
        /// 作用域与档案），报告 = 该会话本回合的最后一条 assistant 消息。
        var windowSessionID: UUID?
        var windowLabel: String?
        /// v0.8.10 crew 可靠性：跨窗 worker 的换窗重试计数（0/1）。
        var windowRetryCount = 0
        /// 依赖编排（v0.8.16）：前序任务下标——done 才派发，failed/cancelled
        /// 级联跳过。只允许引用更早的下标（校验在 dispatch 入口）。
        var dependsOn: Int?
        /// 运行耗时（秒）——done/failed 落定时写，crew 摘要与审计用。
        var durationSeconds: Double? {
            guard let startedAt else { return nil }
            return (finishedAt ?? Date()).timeIntervalSince(startedAt)
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

    /// 进展发布节流（≥1s 一次）：WorkerTask 是引用类型，字段变更不会自动
    /// 触发 ObservableObject——面板靠这里手动发布，节流防每 token 一次重绘。
    private var lastProgressPublish = Date.distantPast

    private func noteProgress(_ worker: WorkerTask, step: String) {
        worker.currentStep = step
        publishProgress()
    }

    /// 节流发布（≥1s）：token 流式上报很密，面板不需要每个 token 重绘。
    private func publishProgress() {
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublish) >= 1 else { return }
        lastProgressPublish = now
        objectWillChange.send()
    }

    /// 终态/取消这类一次性变化立即发布（不等节流，避免面板停在 running）。
    private func publishNow() { objectWillChange.send() }

    /// worker 允许的工具（只读研究子集——不给 click/fill/下载/写入）。
    private static let workerToolNames: Set<String> = [
        "getPageSnapshot", "getPageText", "getPageLinks", "findInPage", "extractTables",
    ]

    private init() {}

    // MARK: - Dispatch (crewDispatch tool)

    @discardableResult
    func dispatch(objective: String, tasks: [(url: String?, instruction: String, dependsOn: Int?)],
                  surface: BrowserToolSurface, isolated: Bool = false,
                  windowMode: Bool = false) -> String {
        guard crew == nil || crew?.isSettled == true else {
            return "A crew is already running. Use crewStatus to poll or crewCancel first."
        }
        guard !tasks.isEmpty else { return "No tasks provided" }
        guard tasks.count <= 6 else { return "At most 6 subtasks per crew" }
        guard let manager = surface.tabManager else { return "No tab manager" }
        // 依赖校验：只许引用更早的下标（环/前向引用直接拒绝——串行与并行
        // 两种模式都以"更早索引先落定"为前提）。
        for (i, t) in tasks.enumerated() {
            if let dep = t.dependsOn, !(0..<i).contains(dep) {
                return "Error: tasks[\(i)].dependsOn must reference an EARLIER task index (0..\(i - 1))"
            }
        }
        if windowMode {
            return dispatchAcrossWindows(objective: objective, tasks: tasks)
        }

        let jsEnabled = surface.settings.isJavaScriptEnabled
        usage = TokenUsage()   // 新 crew 从零累计
        // 任务级隔离：全 crew 标签共享一个临时容器，落定后擦除。
        if isolated {
            let container = ContainerStore.shared.addContainer(
                name: "Agent 隔离-" + UUID().uuidString.prefix(6))
            ephemeralContainerID = container.id
        }
        var workers: [WorkerTask] = []
        for (i, t) in tasks.enumerated() {
            // 每个子任务一个专属后台标签（不抢选中态）。
            manager.addTab(url: t.url, javaScriptEnabled: jsEnabled,
                           contentBlocker: surface.contentBlocker,
                           videoAdBlocker: surface.videoAdBlocker,
                           autoPlayPolicy: .never, newTabPosition: .end,
                           containerID: ephemeralContainerID)
            let tab = manager.tabs.last
            let worker = WorkerTask(index: i, instruction: t.instruction,
                                    url: t.url, tabID: tab?.id)
            worker.dependsOn = t.dependsOn
            workers.append(worker)
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
                if self.shouldSkipDependent(worker) { continue }
                await self.runWorker(worker, surface: surface)
            }
        }
        return """
        Crew dispatched: "\(objective)" with \(workers.count) subtask(s), each on its own tab.
        Use crewStatus to poll progress. Final reports aggregate when all settle.
        """
    }

    /// 单个 worker：单向流式循环，工具面钉在 worker 标签的 webview。
    // MARK: - 跨窗 crew v2（v0.8.8）

    /// 多窗分发：子任务轮转派给**其他窗口**的空闲 Agent 会话（每窗独立
    /// 工具作用域与档案；真正的并行回合）。没有其他窗口时返回失败说明，
    /// 模型可退回默认标签模式。本窗不参与（领队回合正占着它）。
    private func dispatchAcrossWindows(objective: String,
                                       tasks: [(url: String?, instruction: String, dependsOn: Int?)]) -> String {
        let myStore = AgentScheduler.shared.deliveryTarget
        let candidates = AgentScheduler.shared.liveSessions().filter { entry in
            guard let store = entry.store, store !== myStore else { return false }
            return !store.isProcessing && !store.awaitingQuestion
        }
        guard !candidates.isEmpty else {
            return "Error: window mode needs at least one OTHER window with an idle agent session — open another window or fall back to default tab mode"
        }
        usage = TokenUsage()
        var workers: [WorkerTask] = []
        for (i, t) in tasks.enumerated() {
            let target = candidates[i % candidates.count]
            let worker = WorkerTask(index: i, instruction: t.instruction, url: t.url, tabID: nil)
            worker.windowSessionID = target.id
            worker.windowLabel = target.displayLabel
            worker.dependsOn = t.dependsOn
            workers.append(worker)
        }
        let c = Crew(objective: objective, tasks: workers)
        crew = c
        BridgeEventBus.shared.publish("crewStarted", [
            "objective": objective, "tasks": workers.count, "mode": "windows",
        ])
        // 各窗并行起步：每个 worker 一个独立 Task 等待目标会话的回合完成。
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for worker in c.tasks {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        // 依赖门控（v0.8.16）：前序 done 才跑；失败/取消级联跳过。
                        guard await self.awaitDependency(worker, crew: c) else { return }
                        await self.runWindowWorker(worker)
                    }
                }
            }
        }
        return "Crew dispatched across \(candidates.count) window session(s): "
            + candidates.map { $0.displayLabel }.joined(separator: ", ")
            + ". Poll crewStatus."
    }

    /// 窗口 worker：把子任务发给目标窗口的会话，轮询其回合完成，取最后
    /// 一条 assistant 消息为报告。用量按该会话本回合新增消息的 token 字段
    /// 记账（窗口会话自己的成本台账照常随会话落盘）。
    /// 等待前序任务落定（窗口模式并行路径）：done 放行；
    /// failed/cancelled 把本任务置 cancelled 并注明后返回 false。
    private func awaitDependency(_ worker: WorkerTask, crew c: Crew) async -> Bool {
        guard let dep = worker.dependsOn, c.tasks.indices.contains(dep) else { return true }
        let pred = c.tasks[dep]
        while pred.state != .done, worker.state == .pending, !Task.isCancelled {
            if pred.state == .failed || pred.state == .cancelled {
                worker.state = .cancelled
                worker.result = "skipped: predecessor #\(dep) \(pred.state.rawValue)"
                worker.finishedAt = Date()
                publishNow()
                return false
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return worker.state == .pending
    }

    /// 依赖跳过判定（标签模式串行路径）：前序非 done → 本任务取消并注明。
    private func shouldSkipDependent(_ worker: WorkerTask) -> Bool {
        guard let dep = worker.dependsOn, crew?.tasks.indices.contains(dep) == true,
              let pred = crew?.tasks[dep], pred.state != .done else { return false }
        worker.state = .cancelled
        worker.result = "skipped: predecessor #\(dep) \(pred.state.rawValue)"
        worker.finishedAt = Date()
        publishNow()
        return true
    }

    private func runWindowWorker(_ worker: WorkerTask) async {
        await runWindowWorkerOnce(worker)
        // 换窗重试（v0.8.10 crew 可靠性）：失败且还没重试过 → 找另一个空闲
        // 窗口会话再跑一次（不含已用过的窗）。重试也失败就保持失败终态。
        if worker.state == .failed, worker.windowRetryCount == 0 {
            let exclude = worker.windowSessionID
            let alt = AgentScheduler.shared.liveSessions().first { entry in
                entry.id != exclude && entry.store != nil
                    && !entry.store!.isProcessing && !entry.store!.awaitingQuestion
            }
            if let alt {
                worker.windowRetryCount += 1
                worker.windowSessionID = alt.id
                worker.windowLabel = alt.displayLabel
                worker.state = .pending
                worker.result = nil
                worker.startedAt = nil
                worker.finishedAt = nil
                noteProgress(worker, step: String(localized: "Retrying on another window"))
                publishNow()
                await runWindowWorkerOnce(worker)
            }
        }
    }

    private func runWindowWorkerOnce(_ worker: WorkerTask) async {
        guard let sessionID = worker.windowSessionID,
              let entry = AgentScheduler.shared.liveSessions().first(where: { $0.id == sessionID }),
              let store = entry.store else {
            worker.state = .failed
            worker.result = "target window session vanished"
            worker.finishedAt = Date()
            publishNow()
            settleIfDone()
            return
        }
        worker.state = .running
        worker.startedAt = Date()
        defer { worker.finishedAt = Date() }
        let baselineCount = store.messages.count
        let prompt = """
        [Crew subtask #\(worker.index + 1)] \(worker.instruction)
        Start URL: \(worker.url ?? "(none given — search or pick a page yourself)")
        Work with the tools bound to THIS window, then end your turn with a concise factual report (key facts + source URLs).
        """
        noteProgress(worker, step: String(localized: "Dispatched to window session"))
        store.sendMessage(prompt, recordHistory: false)
        let deadline = Date().addingTimeInterval(6 * 60)
        while Date() < deadline {
            if Task.isCancelled || worker.state == .cancelled {
                if worker.state != .cancelled { worker.state = .cancelled }
                publishNow()
                settleIfDone()
                return
            }
            if !store.isProcessing, store.messages.count > baselineCount {
                break
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        guard !Task.isCancelled, worker.state != .cancelled else { return }
        let fresh = store.messages.dropFirst(baselineCount)
        // 报告 = 该回合最后一条 assistant 正文；用量按新增消息的 token 字段累计。
        let report = fresh.last(where: { $0.role == .assistant })?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for m in fresh {
            usage.promptTokens += m.promptTokens ?? 0
            usage.completionTokens += m.completionTokens ?? 0
            worker.promptTokens += m.promptTokens ?? 0
            worker.completionTokens += m.completionTokens ?? 0
            if worker.model == nil, let model = m.model { worker.model = model }
            if usage.model == nil, let model = m.model { usage.model = model }
        }
        worker.toolCallCount = fresh.filter { $0.role == .tool && $0.toolName != nil }.count
        if let report, !report.isEmpty {
            noteProgress(worker, step: String(localized: "Report received"))
            worker.state = .done
            worker.result = report
        } else if store.isProcessing {
            worker.state = .failed
            worker.result = "window session still busy after 6 minutes — poll crewStatus and retry the subtask yourself"
        } else {
            worker.state = .failed
            worker.result = "window session produced no assistant report (turn may have failed — check that window's chat)"
        }
        publishNow()
        settleIfDone()
    }

    private func runWorker(_ worker: WorkerTask, surface: BrowserToolSurface) async {
        guard let tabID = worker.tabID,
              let tab = surface.tabManager?.tabs.first(where: { $0.id == tabID }) else {
            worker.state = .failed
            worker.result = "worker tab vanished"
            worker.finishedAt = Date()
            publishNow()
            settleIfDone()
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
        var round = 0
        for _ in 0..<10 {
            round += 1
            noteProgress(worker, step: String(format: String(localized: "Thinking (round %lld)"), round))
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
                    case .usage(let prompt, let completion):
                        usage.promptTokens += prompt
                        usage.completionTokens += completion
                        worker.promptTokens += prompt
                        worker.completionTokens += completion
                        publishProgress()
                    case .model(let name):
                        if usage.model == nil { usage.model = name }
                        if worker.model == nil { worker.model = name }
                        publishProgress()
                    }
                }
            } catch {
                if worker.state != .cancelled {
                    worker.state = .failed
                    worker.result = "model error: \(error.localizedDescription)"
                }
                publishNow()
                settleIfDone()
                return
            }
            if !text.isEmpty {
                transcript.append(AgentMessage(role: .assistant, content: text, toolCalls: toolCalls.isEmpty ? nil : toolCalls))
            } else if !toolCalls.isEmpty {
                transcript.append(AgentMessage(role: .assistant, content: nil, toolCalls: toolCalls))
            }

            if toolCalls.isEmpty {
                // 无工具调用 = 最终报告。
                noteProgress(worker, step: String(localized: "Writing the report"))
                worker.state = .done
                worker.result = text.isEmpty ? "(empty report)" : text
                publishNow()
                settleIfDone()
                return
            }
            for call in toolCalls {
                calls += 1
                worker.toolCallCount = calls
                noteProgress(worker, step: String(format: String(localized: "Calling %@"), call.function.name))
                guard calls <= 8 else {
                    worker.state = .failed
                    worker.result = "tool-call budget exhausted"
                    publishNow()
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
        publishNow()
        settleIfDone()
    }

    /// 任务级隔离容器（isolated dispatch 时创建；落定即擦除）。
    private var ephemeralContainerID: UUID?

    private func settleIfDone() {
        guard var c = crew, c.isSettled else { return }
        c.finishedAt = Date()
        crew = c
        BridgeEventBus.shared.publish("crewSettled", [
            "objective": c.objective,
            "done": c.completedCount,
            "failed": c.failedCount,
        ])
        // crew 远端通知（v0.8.11）：urgent 级直推（长任务不必盯着）——
        // 标题带 objective，正文带完成/失败计数与总耗时；点通知开 Agent
        // 面板（deepLink "agent" 走既有 NotificationRouter 通道）。
        guard let finishedAt = c.finishedAt else {
            onCrewSettled?(c)
            return
        }
        let elapsed = Int(c.createdAt.distance(to: finishedAt))
        let elapsedText = elapsed >= 60
            ? String(localized: "\(elapsed / 60) min \(elapsed % 60) s")
            : String(localized: "\(elapsed) s")
        onCrewSettled?(c)
        // crew 报告落盘（v0.8.15）：各窗报告合成一份 Markdown 进工作区并入账
        // 最近本地文件——跑完的成果不再只活在聊天记录里；Remote 端 recentFiles
        // 帧随之可见。失败（盘满等）静默：会话内摘要仍是主通道。
        let reportURL = writeCrewReport(c)
        // 通知在报告落盘后发（v0.8.17：正文可带报告文件名）。
        var body = String(localized: "\(c.completedCount) done, \(c.failedCount) failed · \(elapsedText)")
        if let reportURL {
            body += "\n" + String(localized: "Report: \(reportURL.lastPathComponent)")
        }
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Crew finished: \(c.objective)"),
            body: body,
            tier: .urgent)
        if let id = ephemeralContainerID {
            ephemeralContainerID = nil
            Task { @MainActor in
                await ContainerStore.shared.purgeData(for: id)
                ContainerStore.shared.removeContainer(id)
                Log.agent.info("isolated crew container wiped: \(id.uuidString.prefix(8), privacy: .public)")
            }
        }
    }

    // MARK: - Status / Cancel（crew 工具 + 桥共用）

    /// crew 报告 → 工作区 `crew-<时间>-<主题>.md`（主题取 objective 前 24 字符、
    /// 路径非法字符折叠）。每任务一节：状态/耗时/（跨窗时）窗口标签 + 报告全文。
    /// 报告模板（v0.8.17 替人干活 15）：UserDefaults 可自定义段落结构，
    /// 占位符 {{objective}}/{{done}}/{{failed}}/{{duration}}/{{usage}}/{{tasks}}；
    /// 未设置 = 内置默认结构。{{tasks}} 展开为逐任务小节，其余为行内文本。
    private func renderReportBody(_ c: Crew, tasksSection: String) -> String {
        let template = UserDefaults.standard.string(forKey: "crew.reportTemplate")
        guard var template, template.contains("{{") else {
            var md = "# Crew: \(c.objective)\n\n"
            md += "- \(c.completedCount)/\(c.tasks.count) done"
            if c.failedCount > 0 { md += "，\(c.failedCount) failed" }
            if let finishedAt = c.finishedAt {
                md += " · \(Int(c.createdAt.distance(to: finishedAt)))s"
            }
            md += "\n"
            md += tasksSection
            return md
        }
        var usageLine = ""
        if !usage.isEmpty {
            usageLine = String(format: "%d prompt / %d completion tokens", usage.promptTokens, usage.completionTokens)
        }
        template = template
            .replacingOccurrences(of: "{{objective}}", with: c.objective)
            .replacingOccurrences(of: "{{done}}", with: "\(c.completedCount)")
            .replacingOccurrences(of: "{{failed}}", with: "\(c.failedCount)")
            .replacingOccurrences(of: "{{duration}}", with: c.finishedAt.map { "\(Int(c.createdAt.distance(to: $0)))s" } ?? "-")
            .replacingOccurrences(of: "{{usage}}", with: usageLine)
            .replacingOccurrences(of: "{{tasks}}", with: tasksSection)
        return template
    }

    @discardableResult
    private func writeCrewReport(_ c: Crew) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let theme = c.objective
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTheme = String(theme.prefix(24)).isEmpty ? "crew" : String(theme.prefix(24))
        let url = AgentWorkspace.shared.directory
            .appendingPathComponent("crew-\(stamp.string(from: c.createdAt))-\(safeTheme).md")
        var tasksSection = ""
        for t in c.tasks {
            tasksSection += "\n---\n\n## Task \(t.index): \(t.instruction)\n\n"
            if let urlText = t.url, !urlText.isEmpty { tasksSection += "- url: \(urlText)\n" }
            if let label = t.windowLabel { tasksSection += "- window: \(label)\n" }
            if let secs = t.durationSeconds { tasksSection += String(format: "- duration: %.0fs\n", secs) }
            tasksSection += "- state: \(t.state.rawValue)\n"
            if let r = t.result, !r.isEmpty {
                tasksSection += "\n\(r)\n"
            }
        }
        let md = renderReportBody(c, tasksSection: tasksSection)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            RecentLocalFiles.record(url: url)
            return url
        } catch {
            Log.agent.error("crew report write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func statusReport() -> String {
        var usageLine = ""
        if !usage.isEmpty {
            usageLine = String(format: "\n[usage] %d prompt / %d completion tokens",
                               usage.promptTokens, usage.completionTokens)
        }
        guard let c = crew else { return "No crew has been dispatched" }
        let lines = c.tasks.map { t -> String in
            var line = "[\(t.index)] \(t.state.rawValue.uppercased()) — \(t.instruction.prefix(70))"
            if t.totalTokens > 0 {
                line += String(format: " [%d tokens%@]", t.totalTokens,
                               t.model.map { " · \($0)" } ?? "")
            }
            if let secs = t.durationSeconds, t.state != .pending, t.state != .running {
                line += String(format: " (%.0fs)", secs)
            }
            if t.windowRetryCount > 0 {
                line += String(localized: " (retried on another window ×\(t.windowRetryCount))")
            }
            if let r = t.result { line += "\n    → \(r.prefix(600))" }
            return line
        }
        let head = "Crew \"\(c.objective)\": \(c.completedCount)/\(c.tasks.count) done" +
            (c.failedCount > 0 ? ", \(c.failedCount) failed" : "") +
            (c.isSettled ? " (settled — aggregate now)" : "") + usageLine
        return head + "\n" + lines.joined(separator: "\n")
    }

    @discardableResult
    func cancel(taskIndex: Int) -> String {
        guard let c = crew, c.tasks.indices.contains(taskIndex) else { return "No such task index" }
        let t = c.tasks[taskIndex]
        // worker 串行跑在同一个父 Task 里，没有独立句柄可 cancel；停止靠
        // state 标志（runWorker 每轮/每个流事件都会检查），这里立刻置位。
        t.state = .cancelled
        t.finishedAt = Date()
        // 跨窗 v2 级联（v0.8.10）：窗口 worker 的回合跑在**目标窗口的会话**
        // 里——只标本地状态的话那边继续烧模型。给目标会话发取消。
        if let sid = t.windowSessionID,
           let entry = AgentScheduler.shared.liveSessions().first(where: { $0.id == sid }),
           let store = entry.store, store.isProcessing {
            store.cancel()
            return "Cancelled subtask \(taskIndex) (target window turn cancelled too)"
        }
        publishNow()
        settleIfDone()
        return "Cancelled subtask \(taskIndex)"
    }

    /// 清掉进度条（落定后的 ✕ / 测试收尾）。运行中不清——那是 cancelAll 的事。
    func clear() {
        guard let c = crew, c.isSettled else { return }
        crew = nil
    }

    func cancelAll() {
        guard let c = crew else { return }
        var cascaded: Set<UUID> = []
        for t in c.tasks where !t.state.isTerminal {
            t.state = .cancelled
            t.finishedAt = Date()
            if let sid = t.windowSessionID { cascaded.insert(sid) }
        }
        // 级联取消全部涉事窗口的在跑回合（每窗一次）。
        for sid in cascaded {
            guard let entry = AgentScheduler.shared.liveSessions().first(where: { $0.id == sid }),
                  let store = entry.store, store.isProcessing else { continue }
            store.cancel()
        }
        publishNow()
        settleIfDone()
    }
}
