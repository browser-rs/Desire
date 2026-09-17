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

    private static let storageKey = "agent-scheduled-tasks"
    private static let log = Log.agent
    private var clock: Timer?

    private init() {
        tasks = DiskStore.load([ScheduledTask].self, key: Self.storageKey) ?? []
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

    // MARK: - Firing

    /// Fires every due, enabled task. Runs on a 20s wall clock.
    func evaluate(now: Date = Date()) {
        for idx in tasks.indices where tasks[idx].isEnabled {
            guard isDue(tasks[idx], now: now) else { continue }
            let task = tasks[idx]
            tasks[idx].lastFiredAt = now
            if let target = deliveryTarget {
                target.deliverScheduled(task.prompt, from: task.name)
                tasks[idx].lastResult = "delivered"
                Self.log.info("Scheduled task '\(task.name, privacy: .public)' delivered")
            } else {
                tasks[idx].lastResult = String(localized: "missed — no agent session was open")
                Self.log.info("Scheduled task '\(task.name, privacy: .public)' had no delivery target")
            }
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
