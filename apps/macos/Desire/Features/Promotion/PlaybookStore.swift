import Combine
import Foundation

/// 运营 Playbook 库（v0.8.2）。持久化 + 轻量 CRUD；运行由调用方把
/// `PlaybookRun.compose` 的结果交给 Agent（面板/桥/定时任务同一条路）。
@MainActor
final class PlaybookStore: ObservableObject {
    static let shared = PlaybookStore()

    @Published private(set) var playbooks: [Playbook] = []

    private static let storageKey = "ops.playbooks"

    private init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if let loaded = DiskStore.load([Playbook].self, key: Self.storageKey) {
            playbooks = loaded
        } else {
            playbooks = PlaybookTemplate.all(version: version)
            save()
        }
    }

    func playbook(id: UUID) -> Playbook? {
        playbooks.first { $0.id == id }
    }

    func matches(_ query: String) -> [Playbook] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return playbooks }
        return playbooks.filter {
            $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q)
        }
    }

    @discardableResult
    func save(_ playbook: Playbook) -> Playbook {
        var updated = playbook
        updated.updatedAt = Date()
        if let idx = playbooks.firstIndex(where: { $0.id == updated.id }) {
            playbooks[idx] = updated
        } else {
            playbooks.insert(updated, at: 0)
        }
        save()
        return updated
    }

    func delete(_ id: UUID) {
        playbooks.removeAll { $0.id == id }
        save()
    }

    /// 组合后的 prompt（nil = 缺必填参数）。
    func compose(id: UUID, values: [String: String]) -> String? {
        guard let playbook = playbook(id: id),
              PlaybookRun.missingRequired(playbook, values: values).isEmpty else { return nil }
        return PlaybookRun.compose(playbook, values: values)
    }

    // MARK: - 定时

    func taskName(for playbook: Playbook) -> String {
        "Playbook: \(playbook.name)"
    }

    func scheduledTask(for playbook: Playbook) -> AgentScheduler.ScheduledTask? {
        AgentScheduler.shared.tasks.first { $0.name == taskName(for: playbook) }
    }

    /// 用默认参数排程；必填项没有默认值则拒绝。
    @discardableResult
    func schedule(_ playbook: Playbook,
                  recurrence: AgentScheduler.ScheduledTask.Recurrence) -> Bool {
        guard PlaybookRun.missingRequired(playbook, values: [:]).isEmpty else { return false }
        let prompt = PlaybookRun.compose(playbook, values: [:])
        _ = AgentScheduler.shared.remove(named: taskName(for: playbook))
        return AgentScheduler.shared.add(name: taskName(for: playbook),
                                         prompt: prompt,
                                         recurrence: recurrence) != nil
    }

    func unschedule(_ playbook: Playbook) {
        _ = AgentScheduler.shared.remove(named: taskName(for: playbook))
    }

    private func save() {
        DiskStore.save(playbooks, key: Self.storageKey)
    }
}
