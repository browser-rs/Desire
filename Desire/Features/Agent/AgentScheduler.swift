import Combine
import Foundation
import os
import UserNotifications

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
        }

        let id: UUID
        var name: String
        var prompt: String
        var recurrence: Recurrence
        var isEnabled: Bool
        var createdAt: Date
        /// Seed with `createdAt` so intervals count from creation and a
        /// daily task never fires before its first scheduled time.
        var lastFiredAt: Date?
        /// Human-readable outcome of the most recent firing.
        var lastResult: String?

        var recurrenceText: String {
            switch recurrence {
            case .everyMinutes(let minutes):
                return String(localized: "every \(minutes) min")
            case .daily(let hour, let minute):
                return String(format: String(localized: "daily at %02d:%02d"), hour, minute)
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

        var displayLabel: String { "Window \(index + 1)" }
    }

    private final class WeakBox {
        weak var store: AgentSessionStore?
        init(_ store: AgentSessionStore) { self.store = store }
    }

    private var registered: [(id: UUID, box: WeakBox, at: Date)] = []

    @discardableResult
    func registerSession(_ store: AgentSessionStore) -> UUID {
        let id = UUID()
        registered.append((id, WeakBox(store), Date()))
        return id
    }

    func session(withID id: UUID) -> AgentSessionStore? {
        liveSessions().first(where: { $0.id == id })?.store
    }

    func liveSessions() -> [RegisteredSession] {
        registered.removeAll { $0.box.store == nil }
        return registered.enumerated().map { index, entry in
            RegisteredSession(id: entry.id, store: entry.box.store, registeredAt: entry.at, index: index)
        }
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
    func add(name: String, prompt: String, recurrence: ScheduledTask.Recurrence) -> ScheduledTask? {
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
            lastResult: nil
        )
        tasks.append(task)
        save()
        return task
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
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
    /// watching; the failure must surface).
    private func notifyRunFailure(_ record: RunRecord) {
        let center = UserNotifications.UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UserNotifications.UNMutableNotificationContent()
            content.title = String(localized: "Scheduled task failed")
            content.body = "\(record.taskName): \(record.error ?? "unknown error")"
            center.add(UserNotifications.UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
        BridgeEventBus.shared.publish("scheduledTaskFailed", [
            "task": record.taskName,
            "error": record.error ?? "",
            "attempts": record.attempts,
        ])
    }

    /// Retry policy: one automatic retry ~30 s after a failed turn. The task
    /// may be removed/disabled while waiting — then the failure stands.
    private func scheduleRetry(_ record: RunRecord) {
        let taskName = record.taskName
        let runID = record.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            guard let task = self.tasks.first(where: { $0.name == taskName }),
                  task.isEnabled else { return }
            Log.agent.info("retrying scheduled task '\(taskName, privacy: .public)'")
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
        } else {
            notifyRunFailure(record)
            if record.attempts < 2 {
                scheduleRetry(record)
            }
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
        guard let target = deliveryTarget else {
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
        target.addTurnFinishHandler { [weak self] outcome in
            self?.finishRun(id: runID, outcome: outcome)
        }
        target.deliverScheduled(task.prompt, from: task.name)
        if let i = taskIndex { tasks[i].lastResult = "delivered" }
        Self.log.info("Scheduled task '\(task.name, privacy: .public)' delivered")
    }

    /// Fires every due, enabled task. Runs on a 20s wall clock.
    func evaluate(now: Date = Date()) {
        for idx in tasks.indices where tasks[idx].isEnabled {
            guard isDue(tasks[idx], now: now) else { continue }
            let task = tasks[idx]
            tasks[idx].lastFiredAt = now
            deliver(task: task)
        }
        save()
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
        }
    }
}
