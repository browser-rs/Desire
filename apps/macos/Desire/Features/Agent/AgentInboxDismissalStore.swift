import Combine
import Foundation

/// 收件箱"忽略 / 稍后"的持久化台账（v0.7.22 批处理）：按**条目 id** 隐藏
/// 派生条目——收件箱条目是每次实时派生的（`AgentInbox.build`），隐藏必须
/// 记在 id 上并在构建后过滤；id 形状见 AgentInbox（`interrupted-<uuid>`、
/// `unanswered-<uuid>`、`run-<任务>-<时间戳>` 等，稳定可复得）。
///
/// 语义：忽略 = 永久隐藏（可从"已隐藏"恢复）；稍后 = 到期自动回到列表
/// （加载/每次读取时清理过期项）。周报的"待办计数"也走同一过滤——隐藏的
/// 不该在回顾里复活。
@MainActor
final class AgentInboxDismissalStore: ObservableObject {
    static let shared = AgentInboxDismissalStore()

    @Published private(set) var ignored: Set<String> = []
    /// id → 隐藏截止时刻。
    @Published private(set) var snoozed: [String: Date] = [:]

    private static let ignoredKey = "agentInbox.ignored"
    private static let snoozedKey = "agentInbox.snoozed"

    init() {
        ignored = Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.snoozedKey),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            snoozed = decoded
        }
        purgeExpired()
    }

    /// 该 id 当前是否被隐藏（构建期过滤用）。
    func isHidden(_ id: String, now: Date = Date()) -> Bool {
        if ignored.contains(id) { return true }
        if let until = snoozed[id] { return until > now }
        return false
    }

    var hiddenCount: Int { ignored.count + snoozed.count }

    func ignore(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { snoozed.removeValue(forKey: id) }
        ignored.formUnion(ids)
        save()
    }

    func snooze(_ ids: [String], until: Date) {
        guard !ids.isEmpty else { return }
        for id in ids { ignored.remove(id); snoozed[id] = until }
        save()
    }

    /// 恢复（nil = 全部）。返回实际恢复条数。
    @discardableResult
    func restore(ids: [String]? = nil) -> Int {
        if let ids, !ids.isEmpty {
            let hit = ids.filter { ignored.contains($0) || snoozed[$0] != nil }.count
            for id in ids { ignored.remove(id); snoozed.removeValue(forKey: id) }
            save()
            return hit
        }
        let hit = hiddenCount
        ignored.removeAll()
        snoozed.removeAll()
        save()
        return hit
    }

    /// 过期稍后项落回列表（加载与每次读取时调用，幂等）。
    func purgeExpired(now: Date = Date()) {
        let before = snoozed.count
        snoozed = snoozed.filter { $0.value > now }
        if snoozed.count != before { save() }
    }

    private func save() {
        UserDefaults.standard.set(Array(ignored), forKey: Self.ignoredKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(snoozed), forKey: Self.snoozedKey)
    }
}
