import Combine
import Foundation

/// 站点级 Agent 偏好存储（v0.8.25）。本机数据，不进同步域（隔离容器与
/// 审批姿态是机器/环境相关的决定）。
@MainActor
final class SiteAgentPreferenceStore: ObservableObject {
    static let shared = SiteAgentPreferenceStore()

    @Published private(set) var preferences: [SiteAgentPreference] = []

    private static let key = "site-agent-prefs"

    private init() {
        preferences = DiskStore.load([SiteAgentPreference].self, key: Self.key) ?? []
    }

    func preference(for host: String?) -> SiteAgentPreference? {
        guard let normalized = SiteAgentPreferenceCore.normalizeHost(host) else { return nil }
        return preferences.first(where: { $0.host == normalized })
    }

    /// 更新（不存在则创建）；三开关全关时删掉记录。
    @discardableResult
    func update(host: String, autoOperate: Bool? = nil,
                requireConfirmation: Bool? = nil,
                alwaysIsolate: Bool? = nil) -> SiteAgentPreference? {
        guard let normalized = SiteAgentPreferenceCore.normalizeHost(host) else { return nil }
        let existing = preferences.first(where: { $0.host == normalized })
            ?? SiteAgentPreference(host: normalized)
        let updated = SiteAgentPreferenceCore.apply(
            existing: existing, autoOperate: autoOperate,
            requireConfirmation: requireConfirmation, alwaysIsolate: alwaysIsolate)
        if SiteAgentPreferenceCore.isEmpty(updated) {
            preferences.removeAll { $0.host == normalized }
            save()
            return nil
        }
        if let index = preferences.firstIndex(where: { $0.host == normalized }) {
            preferences[index] = updated
        } else {
            preferences.append(updated)
        }
        save()
        return updated
    }

    func remove(host: String) {
        guard let normalized = SiteAgentPreferenceCore.normalizeHost(host) else { return }
        guard preferences.contains(where: { $0.host == normalized }) else { return }
        preferences.removeAll { $0.host == normalized }
        save()
    }

    func payload() -> [String: Any] {
        [
            "preferences": preferences.sorted { $0.host < $1.host }.map { pref -> [String: Any] in
                [
                    "host": pref.host,
                    "autoOperate": pref.autoOperate,
                    "requireConfirmation": pref.requireConfirmation,
                    "alwaysIsolate": pref.alwaysIsolate,
                    "updatedAt": pref.updatedAt.timeIntervalSince1970,
                ]
            },
        ]
    }

    private func save() {
        DiskStore.save(preferences, key: Self.key)
    }
}
