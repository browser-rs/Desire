import Combine
import Foundation

/// Agent 写入回滚（v0.8.10）：把一次回合内 Agent 对书签/阅读列表的批量
/// 写入记成一笔可撤销的"改动组"——面板/桥一键还原。白板量大且有自己的
/// undo（v0.7.x），不在此列。纯逻辑（Foundation-only，进 harness）。
nonisolated enum AgentWriteUndo {

    struct Change: Codable, Equatable {
        enum Target: String, Codable { case bookmark, readingItem }

        /// 真实实体 id。
        let entityID: UUID
        let target: Target
        /// add / remove / update。
        let operation: String
        /// 还原所需的载荷快照：add→还原要删；remove→要有副本才能复建；
        /// update→存旧值。统一存整条 JSON（Bookmark/ReadingListItem 都是
        /// Codable），还原时按 target 解码重放。
        let snapshotJSON: String?
    }

    struct ChangeGroup: Codable, Equatable {
        let id: UUID
        let conversationID: UUID?
        let startedAt: Date
        var changes: [Change]
        var closedAt: Date?

        var isRevertible: Bool { !changes.isEmpty }
    }

    // MARK: - 纯逻辑：还原计划

    enum RevertStep: Equatable {
        /// 从当前存储删除这条（undo add/update 的 add 面）。
        case remove(entityID: UUID, target: Change.Target)
        /// 把快照重新插回存储（undo remove）。
        case restore(entityID: UUID, target: Change.Target, snapshotJSON: String)
    }

    /// 由改动组倒推出还原步骤（后进先出——同一条目被反复改时按逆序回放）。
    static func revertPlan(for group: ChangeGroup) -> [RevertStep] {
        var plan: [RevertStep] = []
        for change in group.changes.reversed() {
            switch change.operation {
            case "add":
                plan.append(.remove(entityID: change.entityID, target: change.target))
            case "remove":
                if let json = change.snapshotJSON {
                    plan.append(.restore(entityID: change.entityID, target: change.target,
                                         snapshotJSON: json))
                }
            case "update":
                plan.append(.restore(entityID: change.entityID, target: change.target,
                                     snapshotJSON: change.snapshotJSON ?? ""))
            default:
                break
            }
        }
        return plan
    }
}


/// 活跃改动组的记账入口（挂在 owner 会话上；一次回合 = 一组）。
@MainActor
final class AgentWriteUndoRecorder: ObservableObject {
    static let shared = AgentWriteUndoRecorder()

    /// 最近 N 组（上限 24；跨会话共用——面板按会话 id 过滤展示）。
    @Published private(set) var groups: [AgentWriteUndo.ChangeGroup] = []
    private static let cap = 24

    /// 本回合打开一组（AgentSessionStore.runTurn 开始时调用）。
    func beginGroup(conversationID: UUID?) {
        groups.insert(AgentWriteUndo.ChangeGroup(
            id: UUID(), conversationID: conversationID, startedAt: Date(), changes: []), at: 0)
        if groups.count > Self.cap { groups.removeLast(groups.count - Self.cap) }
    }

    func record(target: AgentWriteUndo.Change.Target, operation: String,
                entityID: UUID, snapshotJSON: String?) {
        guard let idx = groups.firstIndex(where: { $0.closedAt == nil }) else { return }
        groups[idx].changes.append(.init(entityID: entityID, target: target,
                                         operation: operation, snapshotJSON: snapshotJSON))
    }

    /// 移除一组（还原完成后调用；revert 扩展用）。
    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
    }

    /// 回合收尾关闭（之后的新写入归下一组）。
    func endGroup() {
        guard let idx = groups.firstIndex(where: { $0.closedAt == nil }) else { return }
        if groups[idx].changes.isEmpty {
            groups.remove(at: idx)
        } else {
            groups[idx].closedAt = Date()
        }
    }

}
