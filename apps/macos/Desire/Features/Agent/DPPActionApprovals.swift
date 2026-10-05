import Foundation

/// DPP 逐动作放行（0.6.7）：用户对「某站点 × 某动作」的显式授权。
///
/// 与访问等级/白名单正交——outbound/danger 升级挡的是**访问等级与白名单的
/// 静默放行**；用户在审批卡上点「本站始终允许」是对该 (host, action) 组合的
/// 点名授权，优先级最高（deny 策略仍前置）。
/// 例外：run 含 mcp 步骤的动作（页面请求宿主侧能力）不参与本表——每次仍
/// 逐次审批（gate 侧跳过）。
/// 持久化 DiskStore（key `dpp-action-approvals`）；设置页/桥可吊销。
/// 既有调用方（gate/resolve）都在 MainActor——直接标 @MainActor 免并发标注。
@MainActor
final class DPPActionApprovals {
    static let shared = DPPActionApprovals()

    struct Rule: Codable, Identifiable, Equatable {
        let id: UUID
        var host: String
        var actionName: String
        var createdAt: Date
        var key: String { Self.key(host: host, actionName: actionName) }

        static func key(host: String, actionName: String) -> String {
            "\(host.lowercased())|\(actionName)"
        }
    }

    private static let storageKey = "dpp-action-approvals"
    private var rulesByKey: [String: Rule] = [:]

    private init() {
        let saved = DiskStore.load([Rule].self, key: Self.storageKey) ?? []
        for r in saved { rulesByKey[r.key] = r }
    }

    private var ordered: [Rule] {
        rulesByKey.values.sorted { $0.createdAt < $1.createdAt }
    }

    func all() -> [Rule] { ordered }

    func allows(host: String, actionName: String) -> Bool {
        rulesByKey[Rule.key(host: host, actionName: actionName)] != nil
    }

    func allow(host: String, actionName: String) {
        let key = Rule.key(host: host, actionName: actionName)
        if rulesByKey[key] == nil {
            rulesByKey[key] = Rule(id: UUID(), host: host.lowercased(),
                                   actionName: actionName, createdAt: Date())
            save()
        }
    }

    func revoke(host: String, actionName: String) {
        if rulesByKey.removeValue(forKey: Rule.key(host: host, actionName: actionName)) != nil {
            save()
        }
    }

    func revoke(ruleID: UUID) {
        if let r = ordered.first(where: { $0.id == ruleID }) {
            revoke(host: r.host, actionName: r.actionName)
        }
    }

    func revokeAll() {
        guard !rulesByKey.isEmpty else { return }
        rulesByKey.removeAll()
        save()
    }

    private func save() {
        DiskStore.save(ordered, key: Self.storageKey)
    }
}
