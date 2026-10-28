import Combine
import Foundation
import os

/// Scheduled agent prompts (定时任务). A task re-sends a stored prompt to
/// the agent on a recurrence ("every N minutes" or "daily at HH:MM") while
/// the app is running. Overdue tasks fire once on launch — catch-up, not a
/// stack of missed runs.
///
/// Delivery goes through `AgentSessionStore.deliverScheduled` on the most
/// recently registered session (`deliveryTarget`); if no session is alive
/// the firing is recorded as missed on the task and surfaced in Settings.
/// Created and managed by the agent itself via the scheduleTask tools, and
/// user-editable in Settings → Agent → Scheduled Tasks.
@MainActor
final class AgentScheduler: ObservableObject {
    static let shared = AgentScheduler()

    struct ScheduledTask: Identifiable, Codable {
        enum Recurrence: Codable, Equatable {
            case everyMinutes(Int)
            case daily(hour: Int, minute: Int)
            /// 每周（0.7.15 运营复盘）：weekday 用 Calendar 口径 1=周日…7=周六。
            case weekly(weekday: Int, hour: Int, minute: Int)
        }

        let id: UUID
        var name: String
        var prompt: String
        /// 内置流水线（v0.7.24）：非 nil 时到点**不投递 prompt**，改跑确定性
        /// 流水线（当前唯一值 "weeklyReport"）。旧文件缺键 → nil（可选解码）。
        var builtin: String?
        var recurrence: Recurrence
        var isEnabled: Bool
        var createdAt: Date
        /// Seed with `createdAt` so intervals count from creation and a
        /// daily task never fires before its first scheduled time.
        var lastFiredAt: Date?
        /// 完成后触发链（v0.8.17 替人干活）：本任务**成功**结束时自动投递
        /// 指定名称的任务（一次性链；防环在 setChain 校验）。旧文件缺键 → nil。
        var chainTo: String?
        /// Human-readable outcome of the most recent firing.
        var lastResult: String?
        /// 目标窗口（调度器注册 id，多窗口联动 v1）：nil = 跟随"最新注册的活
        /// 会话"（历史行为）。目标窗口关闭后回落最新会话。
        var targetSessionID: UUID?

        var recurrenceText: String {
            switch recurrence {
            case .everyMinutes(let minutes):
                return String(localized: "every \(minutes) min")
            case .daily(let hour, let minute):
                return String(format: String(localized: "daily at %02d:%02d"), hour, minute)
            case .weekly(let weekday, let hour, let minute):
                let symbols = Calendar.current.weekdaySymbols
                let day = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "\(weekday)"
                return String(format: String(localized: "weekly on %@ at %02d:%02d"), day, hour, minute)
            }
        }
    }

    @Published private(set) var tasks: [ScheduledTask] = []

    /// Set by `AgentSessionStore.init` — the newest live session receives
    /// firing prompts (a second window takes over delivery naturally).
    weak var deliveryTarget: AgentSessionStore?

    // MARK: - Multi-window session registry

    /// Every live agent session (one per main window), addressable by id so
    /// external drivers can route prompts to a SPECIFIC window instead of
    /// the newest one. Weak — entries prune themselves when windows close.
    struct RegisteredSession: Identifiable {
        let id: UUID
        weak var store: AgentSessionStore?
        let registeredAt: Date
        let index: Int
        /// 所属 NSWindow 的 title（注册时快照；仅展示用）。
        var windowTitle: String?

        var displayLabel: String {
            if let windowTitle, !windowTitle.isEmpty { return windowTitle }
            return "Window \(index + 1)"
        }
    }

    private final class WeakBox {
        weak var store: AgentSessionStore?
        init(_ store: AgentSessionStore) { self.store = store }
    }

    private var registered: [(id: UUID, box: WeakBox, at: Date, title: String?)] = []
    private var tabLeases: [UUID: Int] = [:]

    func acquireTabLease(_ tabID: UUID) {
        tabLeases[tabID, default: 0] += 1
    }

    func releaseTabLease(_ tabID: UUID) {
        guard let count = tabLeases[tabID] else { return }
        if count <= 1 { tabLeases.removeValue(forKey: tabID) }
        else { tabLeases[tabID] = count - 1 }
    }

    func isTabLeased(_ tabID: UUID) -> Bool {
        (tabLeases[tabID] ?? 0) > 0
    }

    @discardableResult
    func registerSession(_ store: AgentSessionStore, windowTitle: String? = nil) -> UUID {
        let id = UUID()
        registered.append((id, WeakBox(store), Date(), windowTitle))
        return id
    }

    /// 刷新某会话的窗口标题（窗口标题随活动标签变化——onAppear/换窗时刷）。
    func updateWindowTitle(_ store: AgentSessionStore, title: String?) {
        guard let idx = registered.firstIndex(where: { $0.box.store === store }) else { return }
        registered[idx] = (registered[idx].id, registered[idx].box, registered[idx].at, title)
    }

    /// 打断的**跨面板兜底**：每个窗口/浮窗各持一个会话 store（多 store 结构），
    /// 可见面板的打断只 cancel 自己——若流跑在另一个 store 上（比如另一个
    /// 窗口正在输出的回合），那个按钮就是空操作（用户实测"开关窗口后打断
    /// 无效、只能强退"）。此方法停掉除指定外的所有还在跑的会话。
    func cancelStreamingSessions(except keep: AgentSessionStore?) {
        for entry in liveSessions() {
            guard let store = entry.store, store !== keep, store.isProcessing else { continue }
            store.cancel()
        }
    }

    /// 窗口关闭：若它正是投递目标，**转交**给仍在世的最近注册会话；一个都
    /// 没有就清空（桥/工具据此报"无活会话"，而不是继续打到死窗口上——
    /// 实测：关掉窗口后 deliveryTarget 仍指向它，后续回合的工具全跑在
    /// 一个不可见的死窗口上，点击/导航全部静默失效）。
    func sessionDidClose(_ store: AgentSessionStore) {
        guard deliveryTarget === store else { return }
        let others = liveSessions().compactMap(\.store).filter { $0 !== store }
        deliveryTarget = others.last
        Log.agent.info("delivery target reassigned after window close: \(self.deliveryTarget == nil ? "none" : "next live", privacy: .public)")
    }

    func session(withID id: UUID) -> AgentSessionStore? {
        liveSessions().first(where: { $0.id == id })?.store
    }

    func liveSessions() -> [RegisteredSession] {
        registered.removeAll { $0.box.store == nil }
        return registered.enumerated().map { index, entry in
            RegisteredSession(id: entry.id, store: entry.box.store,
                              registeredAt: entry.at, index: index,
                              windowTitle: entry.title)
        }
    }

    /// 某会话所属 TabManager 的快照（跨窗工具的目标解析用）。
    func tabManager(for sessionID: UUID) -> TabManager? {
        session(withID: sessionID)?.boundTabManager
    }

    private static let storageKey = "agent-scheduled-tasks"
    private static let log = Log.agent
    private var clock: Timer?

    private init() {
        tasks = DiskStore.load([ScheduledTask].self, key: Self.storageKey) ?? []
        loadRuns()
        startClock()
    }

    private func save() {
        DiskStore.save(tasks, key: Self.storageKey)
    }

    private func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
    }

    // MARK: - Management

    @discardableResult
    func add(name: String, prompt: String, recurrence: ScheduledTask.Recurrence,
             targetSessionID: UUID? = nil) -> ScheduledTask? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return nil }
        let task = ScheduledTask(
            id: UUID(),
            name: trimmedName,
            prompt: trimmedPrompt,
            recurrence: recurrence,
            isEnabled: true,
            createdAt: Date(),
            lastFiredAt: Date(),
            lastResult: nil,
            targetSessionID: targetSessionID
        )
        tasks.append(task)
        save()
        return task
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    /// 内置流水线任务（v0.7.24 起；v0.7.25 泛化 kind）：prompt 仅作展示，
    /// 到点走 `deliverBuiltin`。kind ∈ weeklyReport | dailyBrief | workflow:<uuid>。
    @discardableResult
    func addBuiltin(name: String, recurrence: ScheduledTask.Recurrence,
                    kind: String = "weeklyReport",
                    targetSessionID: UUID? = nil) -> ScheduledTask? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              ["weeklyReport", "dailyBrief", "promotionMentionScan"].contains(kind)
                || Self.workflowID(in: kind) != nil
        else { return nil }
        let displayPrompt: String
        if kind == "dailyBrief" {
            displayPrompt = "（内置）每日简报：今日会话/用量/收件箱 → 备注 + 通知"
        } else if kind == "promotionMentionScan" {
            displayPrompt = "（内置）提及雷达：离屏扫描已配置来源，新提及进互动台账"
        } else if let wid = Self.workflowID(in: kind) {
            let workflowName = WorkflowStore.shared.workflows
                .first(where: { $0.id == wid })?.name ?? wid.uuidString
            displayPrompt = "（内置）定时工作流：\(workflowName)"
        } else {
            displayPrompt = "（内置）周报流水线：汇总 → 上板 → 可选备忘录"
        }
        let task = ScheduledTask(
            id: UUID(),
            name: trimmedName,
            prompt: displayPrompt,
            builtin: kind,
            recurrence: recurrence,
            isEnabled: true,
            createdAt: Date(),
            lastFiredAt: Date(),
            lastResult: nil,
            targetSessionID: targetSessionID
        )
        tasks.append(task)
        save()
        return task
    }

    /// 工作流定时（v0.8.1）：同一条工作流只保留一个计划（再次排程 = 更新）。
    @discardableResult
    func scheduleWorkflow(_ workflow: Workflow,
                          recurrence: ScheduledTask.Recurrence) -> ScheduledTask? {
        removeWorkflowSchedule(workflow.id)
        return addBuiltin(name: workflow.name, recurrence: recurrence,
                          kind: "workflow:\(workflow.id.uuidString)")
    }

    func workflowSchedule(for workflowID: UUID) -> ScheduledTask? {
        tasks.first { $0.builtin == "workflow:\(workflowID.uuidString)" }
    }

    func removeWorkflowSchedule(_ workflowID: UUID) {
        let before = tasks.count
        tasks.removeAll { $0.builtin == "workflow:\(workflowID.uuidString)" }
        if tasks.count != before { save() }
    }

    /// 解析 `workflow:<uuid>` 的 id；其他 kind 返回 nil。
    static func workflowID(in kind: String) -> UUID? {
        guard kind.hasPrefix("workflow:") else { return nil }
        return UUID(uuidString: String(kind.dropFirst("workflow:".count)))
    }

    /// Removes by (case-insensitive) name — the cancelScheduledTask tool path.
    @discardableResult
    func remove(named name: String) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        let before = tasks.count
        tasks.removeAll { $0.name.lowercased() == lowered }
        let removed = tasks.count < before
        if removed { save() }
        return removed
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].isEnabled = enabled
        // Re-arming restarts the interval from now.
        tasks[idx].lastFiredAt = Date()
        save()
    }

    /// 设置任务的投递目标窗口（多窗口联动 v1 的设置页入口）。nil = 跟随最新。
    func setTarget(_ sessionID: UUID?, for id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].targetSessionID = sessionID
        save()
    }

    /// 任务行的目标窗口显示名（设置页）。
    func targetLabel(for taskID: UUID) -> String? {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return nil }
        guard let targetID = task.targetSessionID else { return nil }
        return liveSessions().first(where: { $0.id == targetID })?.displayLabel
    }

    var activeCount: Int { tasks.filter(\.isEnabled).count }

    /// Delivers a task's prompt immediately, ignoring the recurrence clock.
    /// The automation bridge's fire endpoint — deterministic E2E for the
    /// scheduled-task pipeline without waiting out an interval.
    @discardableResult
    func fireNow(named name: String) -> Bool {
        guard let idx = tasks.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
            return false
        }
        let task = tasks[idx]
        tasks[idx].lastFiredAt = Date()
        deliver(task: task)
        save()
        return true
    }

    // MARK: - Run history (无人值守作业)

    /// One firing of a task: delivery outcome, turn result, retries.
    /// Persisted (newest 100) — the unattended-jobs audit trail.
    struct RunRecord: Codable, Identifiable {
        let id: UUID
        var taskName: String
        var firedAt: Date
        var finishedAt: Date?
        var status: String // delivered | queued | missed | success | failed
        var success: Bool?
        var error: String?
        var attempts: Int = 1
    }

    @Published private(set) var runs: [RunRecord] = []

    /// 审计聚合（v0.8.10）：折成轻量行进 TaskRunAudit 纯核。
    func audit(days: Int = 30) -> [TaskRunAudit.Audit] {
        TaskRunAudit.derive(rows: runs.map {
            .init(taskName: $0.taskName, firedAt: $0.firedAt, finishedAt: $0.finishedAt,
                  failed: $0.success == false || $0.status == "failed" || $0.status == "missed",
                  error: $0.error)
        }, days: days)
    }

    private static let runsKey = "agent-task-runs"
    private static let maxRuns = 100

    private func recordRun(_ record: RunRecord) {
        runs.insert(record, at: 0)
        if runs.count > Self.maxRuns {
            runs = Array(runs.prefix(Self.maxRuns))
        }
        saveRuns()
    }

    private func saveRuns() {
        DiskStore.save(runs, key: Self.runsKey)
    }

    /// System notification on failed unattended runs (the user isn't
    /// watching; the failure must surface). urgent 档：免打扰时段也直推。
    private func notifyRunFailure(_ record: RunRecord) {
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Scheduled task failed"),
            body: "\(record.taskName): \(record.error ?? "unknown error")",
            tier: .urgent)
        BridgeEventBus.shared.publish("scheduledTaskFailed", [
            "task": record.taskName,
            "error": record.error ?? "",
            "attempts": record.attempts,
        ])
    }

    /// 完成链（v0.8.17 替人干活 14）：任务成功后投递 chainTo 指向的任务
    /// （存在且启用；目标正忙/不存在则静默跳过——链是便利语义不是契约）。
    private func deliverChainedTask(after name: String) {
        guard let task = tasks.first(where: { $0.name == name }),
              let chainedName = task.chainTo,
              let chained = tasks.first(where: { $0.name == chainedName }),
              chained.isEnabled else { return }
        Log.agent.info("task chain: '\(name, privacy: .public)' → '\(chainedName, privacy: .public)'")
        deliver(task: chained)
    }

    /// 设置完成链（工具/桥入口；A→B 直链，深度链由 B→C 续）。
    @discardableResult
    func setChain(from name: String, to chainedName: String?) -> String {
        guard chainedName != name else { return "Error: a task cannot chain to itself" }
        guard tasks.contains(where: { $0.name == name }) else { return "Error: no task named \(name)" }
        if let chainedName {
            guard tasks.contains(where: { $0.name == chainedName }) else {
                return "Error: no task named \(chainedName)"
            }
        }
        guard let idx = tasks.firstIndex(where: { $0.name == name }) else { return "Error: gone" }
        tasks[idx].chainTo = chainedName
        save()
        return chainedName.map { "Chained: \(name) → \($0) (fires after a successful run)" }
            ?? "Chain removed from \(name)"
    }

    /// Retry policy: N retries (user-configurable, default 1) with
    /// exponential backoff (30s, 60s, 120s). The task may be removed/disabled
    /// while waiting — then the failure stands.
    private func scheduleRetry(_ record: RunRecord) {
        let taskName = record.taskName
        let runID = record.id
        let limit = {
            let raw = UserDefaults.standard.integer(forKey: "scheduledTaskRetries")
            return (1...3).contains(raw) ? raw : 1
        }()
        guard record.attempts < 1 + limit else { return }
        let delay = UInt64(30 * (1 << (record.attempts - 1)))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let task = self.tasks.first(where: { $0.name == taskName }),
                  task.isEnabled else { return }
            Log.agent.info("retrying scheduled task '\(taskName, privacy: .public)' (attempt \(record.attempts + 1)/\(1 + limit))")
            self.deliver(task: task, runID: runID, attempts: record.attempts + 1)
        }
    }

    private func updateRun(id: UUID, mutate: (inout RunRecord) -> Void) {
        guard let idx = runs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&runs[idx])
        saveRuns()
    }

    private func finishRun(id: UUID, outcome: AgentSessionStore.TurnOutcome) {
        updateRun(id: id) {
            $0.finishedAt = Date()
            $0.success = outcome.success
            $0.status = outcome.success ? "success" : "failed"
            $0.error = outcome.error
        }
        guard let record = runs.first(where: { $0.id == id }) else { return }
        if outcome.success {
            BridgeEventBus.shared.publish("scheduledTaskSucceeded", ["task": record.taskName])
            deliverChainedTask(after: record.taskName)
        } else {
            notifyRunFailure(record)
            scheduleRetry(record)   // 内部判次数上限（1+可配 N）与退避
        }
    }

    private func loadRuns() {
        runs = DiskStore.load([RunRecord].self, key: Self.runsKey) ?? []
    }

    // MARK: - Firing

    /// Delivers a task's prompt and records the run. The turn-finish handler
    /// attached BEFORE delivery updates the record when the agent turn ends
    /// (success, or failure with error → notification + one retry). A retry
    /// passes the SAME runID so the record accumulates attempts.
    private func deliver(task: ScheduledTask, runID: UUID = UUID(), attempts: Int = 1) {
        let taskIndex = tasks.firstIndex(where: { $0.id == task.id })

        // 定时工作流（v0.8.1）：离屏回放，不需要活 Agent 会话，也不切换
        // 用户标签页——与 prompt/builtin 两条路径分开。
        if let builtin = task.builtin, Self.workflowID(in: builtin) != nil {
            recordRun(RunRecord(
                id: runID, taskName: task.name, firedAt: Date(),
                finishedAt: nil, status: "delivered", success: nil,
                error: nil, attempts: attempts))
            if let i = taskIndex { tasks[i].lastResult = "delivered (workflow)" }
            deliverBuiltin(builtin, task: task, runID: runID)
            return
        }

        // 投递路由（多窗口联动 v1）：任务可点名目标窗口（调度器注册 id）；
        // 目标已关或未点名 → 回落"最新注册的活会话"（与历史行为一致）。
        // `agent.background.force`（自动化/自检用）：即使有活窗口也走后台
        // Runner——用于在不动用户标签页的前提下验证无头执行链路。
        if UserDefaults.standard.bool(forKey: "agent.background.force") {
            startBackground(task: task, runID: runID, attempts: attempts,
                            taskIndex: taskIndex)
            return
        }
        let resolvedTarget = task.targetSessionID.flatMap { session(withID: $0) }
        if task.targetSessionID != nil, resolvedTarget == nil {
            Self.log.info("Scheduled task '\(task.name, privacy: .public)' target window is gone — falling back to the newest session")
        }
        guard let target = resolvedTarget ?? deliveryTarget else {
            // 后台 Agent Runner（v0.8.2）：没有活窗口时在无头标签里跑完整
            // 工具循环，不再直接记 missed（关闭开关后回到旧行为）。
            if BackgroundAgentRunner.shared.isEnabled {
                startBackground(task: task, runID: runID, attempts: attempts,
                                taskIndex: taskIndex)
                return
            }
            if let i = taskIndex { tasks[i].lastResult = String(localized: "missed — no agent session was open") }
            if runs.firstIndex(where: { $0.id == runID }) != nil {
                updateRun(id: runID) {
                    $0.status = "missed"
                    $0.finishedAt = Date()
                    $0.error = "no agent session was open"
                }
            } else {
                recordRun(RunRecord(
                    id: runID, taskName: task.name, firedAt: Date(), finishedAt: Date(),
                    status: "missed", success: nil, error: "no agent session was open", attempts: attempts
                ))
            }
            Self.log.info("Scheduled task '\(task.name, privacy: .public)' had no delivery target")
            return
        }
        if runs.firstIndex(where: { $0.id == runID }) != nil {
            updateRun(id: runID) {
                $0.attempts = attempts
                $0.status = "delivered (retry)"
                $0.finishedAt = nil
            }
        } else {
            recordRun(RunRecord(
                id: runID, taskName: task.name, firedAt: Date(),
                finishedAt: nil, status: "delivered", success: nil, error: nil, attempts: attempts
            ))
        }
        // 内置流水线（v0.7.24）：不投递 prompt，跑确定性管线并按结果收尾 run。
        if let builtin = task.builtin {
            deliverBuiltin(builtin, task: task, runID: runID)
            if let i = taskIndex { tasks[i].lastResult = "delivered (builtin)" }
            Self.log.info("Scheduled builtin '\(builtin, privacy: .public)' fired via task '\(task.name, privacy: .public)'")
            return
        }
        // The turn-finish hook is passed THROUGH deliverScheduled: when the
        // prompt gets queued behind a running turn, the hook rides with the
        // queue entry and binds to its own turn — never to whichever turn
        // ends first.
        target.deliverScheduled(task.prompt, from: task.name) { [weak self] outcome in
            self?.finishRun(id: runID, outcome: outcome)
        }
        if let i = taskIndex { tasks[i].lastResult = "delivered" }
        Self.log.info("Scheduled task '\(task.name, privacy: .public)' delivered")
    }

    /// 无活窗口时的后台投递：无头标签 + 隐藏会话；结果回写 run 记录。
    private func startBackground(task: ScheduledTask, runID: UUID, attempts: Int,
                                 taskIndex: Int?) {
        if runs.firstIndex(where: { $0.id == runID }) != nil {
            updateRun(id: runID) {
                $0.attempts = attempts
                $0.status = "delivered (background)"
                $0.finishedAt = nil
            }
        } else {
            recordRun(RunRecord(
                id: runID, taskName: task.name, firedAt: Date(),
                finishedAt: nil, status: "delivered (background)",
                success: nil, error: nil, attempts: attempts))
        }
        if let i = taskIndex { tasks[i].lastResult = "delivered (background)" }
        Self.log.info("Scheduled task '\(task.name, privacy: .public)' running in the background runner")
        Task { @MainActor [weak self] in
            let outcome = await BackgroundAgentRunner.shared.run(
                prompt: task.prompt, taskName: task.name)
            self?.finishRun(id: runID, outcome: AgentSessionStore.TurnOutcome(
                success: outcome.ok, error: outcome.error))
        }
    }

    /// 内置流水线执行 + run 收尾（失败非致命，记录在 run 上）。
    private func deliverBuiltin(_ builtin: String, task: ScheduledTask, runID: UUID) {
        switch builtin {
        case "weeklyReport":
            Task { @MainActor [weak self] in
                let writeToNotes = UserDefaults.standard.bool(forKey: "agent.weeklyReport.writeToNotes")
                let outcome = await WeeklyReportPipeline.run(days: 7, writeToNotes: writeToNotes)
                self?.updateRun(id: runID) {
                    $0.status = "success"
                    $0.finishedAt = Date()
                    $0.error = nil
                }
                Self.log.info("Weekly report pipeline done: digest=\(outcome.digestChars) chars, board=\(outcome.boardBlocks) blocks, notes=\(outcome.notes, privacy: .public)")
            }
        case "dailyBrief":
            Task { @MainActor [weak self] in
                let text = DailyBriefService.runNow()
                self?.updateRun(id: runID) {
                    $0.status = "success"
                    $0.finishedAt = Date()
                    $0.error = nil
                }
                Self.log.info("Daily brief done: \(text.count) chars")
            }
        case "promotionMentionScan":
            Task { @MainActor [weak self] in
                let store = PromotionStore.shared
                guard !store.enabledMentionSources.isEmpty else {
                    self?.updateRun(id: runID) {
                        $0.status = "success"
                        $0.finishedAt = Date()
                        $0.error = nil
                    }
                    if let i = self?.tasks.firstIndex(where: { $0.id == task.id }) {
                        self?.tasks[i].lastResult = "mention radar: no enabled sources"
                    }
                    return
                }
                let result = await MentionRadarScanner.scan(
                    query: store.mentionQuery, sources: store.mentionSources)
                self?.updateRun(id: runID) {
                    $0.status = "success"
                    $0.finishedAt = Date()
                    $0.error = nil
                }
                if let i = self?.tasks.firstIndex(where: { $0.id == task.id }) {
                    self?.tasks[i].lastResult = "mention radar: +\(result.added) new"
                }
                if result.added > 0 {
                    ProactiveNotificationStore.shared.deliver(
                        title: String(localized: "Mention radar"),
                        body: "\(result.added) new mention(s) for “\(store.mentionQuery)” — review them in Operations.",
                        tier: .routine)
                }
                Self.log.info("Mention radar done: scanned=\(result.scannedSources) added=\(result.added)")
            }
        default:
            if let workflowID = Self.workflowID(in: builtin) {
                Task { @MainActor [weak self] in
                    guard let workflow = WorkflowStore.shared.workflows
                        .first(where: { $0.id == workflowID }) else {
                        self?.updateRun(id: runID) {
                            $0.status = "failed"
                            $0.finishedAt = Date()
                            $0.error = "workflow not found (deleted?)"
                        }
                        if let i = self?.tasks.firstIndex(where: { $0.id == task.id }) {
                            self?.tasks[i].lastResult = "failed — workflow not found"
                        }
                        return
                    }
                    let result = await WorkflowScheduledRunner.run(workflow)
                    let failed = result.results.first(where: { !$0.ok })
                    self?.updateRun(id: runID) {
                        $0.status = result.ok ? "success" : "failed"
                        $0.finishedAt = Date()
                        $0.error = result.ok ? nil : failed?.message
                    }
                    if let i = self?.tasks.firstIndex(where: { $0.id == task.id }) {
                        self?.tasks[i].lastResult = result.ok
                            ? "workflow ok (\(result.results.count) steps)"
                            : "workflow failed: \(failed?.message ?? "unknown")"
                    }
                    ProactiveNotificationStore.shared.deliver(
                        title: result.ok
                            ? String(localized: "Workflow “\(workflow.name)” finished")
                            : String(localized: "Workflow “\(workflow.name)” failed"),
                        body: result.ok
                            ? "\(result.results.count) step(s) completed"
                            : (failed?.message ?? "unknown error"),
                        tier: .routine)
                    Self.log.info("Scheduled workflow '\(workflow.name, privacy: .public)' \(result.ok ? "ok" : "failed", privacy: .public)")
                }
                return
            }
            updateRun(id: runID) {
                $0.status = "failed"
                $0.finishedAt = Date()
                $0.error = "unknown builtin: \(builtin)"
            }
        }
    }

    /// Fires every due, enabled task. Runs on a 20s wall clock. Persisting
    /// happens only when something actually fired — an idle tick must not
    /// rewrite the task file every 20 seconds.
    func evaluate(now: Date = Date()) {
        var firedAny = false
        for idx in tasks.indices where tasks[idx].isEnabled {
            guard isDue(tasks[idx], now: now) else { continue }
            let task = tasks[idx]
            tasks[idx].lastFiredAt = now
            deliver(task: task)
            firedAny = true
        }
        if firedAny { save() }
    }

    private func isDue(_ task: ScheduledTask, now: Date) -> Bool {
        let last = task.lastFiredAt ?? task.createdAt
        switch task.recurrence {
        case .everyMinutes(let minutes):
            return now.timeIntervalSince(last) >= Double(max(5, minutes)) * 60
        case .daily(let hour, let minute):
            let calendar = Calendar.current
            let day = calendar.dateComponents([.year, .month, .day], from: now)
            guard let todayAt = calendar.date(from: DateComponents(
                year: day.year, month: day.month, day: day.day, hour: hour, minute: minute
            )) else { return false }
            return now >= todayAt && !calendar.isDate(last, inSameDayAs: now)
        case .weekly(let weekday, let hour, let minute):
            let calendar = Calendar.current
            guard calendar.component(.weekday, from: now) == weekday else { return false }
            let day = calendar.dateComponents([.year, .month, .day], from: now)
            guard let todayAt = calendar.date(from: DateComponents(
                year: day.year, month: day.month, day: day.day, hour: hour, minute: minute
            )) else { return false }
            return now >= todayAt && !calendar.isDate(last, inSameDayAs: now)
        }
    }
}
