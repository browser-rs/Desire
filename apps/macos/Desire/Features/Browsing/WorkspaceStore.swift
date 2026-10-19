import Combine
import Foundation

/// 窗口级工作区（0.7.13）：命名标签组 + 会话快照，一键整体恢复。
/// 每个"工作区" = 名称 + 一份 SavedSession（标签集/选中索引/档案）+ 保存时间。
/// 保存 = 当前窗口标签序列化（复用 TabManager.appendSessionTabs 的既有序列化，
/// 与会话恢复同格式）；恢复 = 新窗口装载该 SavedSession（走既有 restoreSession
/// 变体）。持久化 DiskStore `workspaces`（单文件数组，量小无需分文件）。
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    struct Workspace: Codable, Identifiable {
        let id: UUID
        var name: String
        var session: SavedSession
        var savedAt: Date

        var displayTitle: String {
            let n = session.tabs.count
            return "\(name) — \(n) tab\(n == 1 ? "" : "s")"
        }
    }

    @Published private(set) var workspaces: [Workspace] = []
    /// 显式删除的墓碑（云同步用，v0.7.25）：单独键持久化——不动既有
    /// [Workspace] 数组的文件形状（旧文件零迁移）。
    @Published private(set) var pendingDeletions: [UUID: Date] = [:]

    private static let storageKey = "workspaces"
    private static let tombstonesKey = "workspaces.pendingDeletions"

    private init() {
        workspaces = DiskStore.load([Workspace].self, key: Self.storageKey)
            ?? []
        workspaces.sort { $0.savedAt > $1.savedAt }
        pendingDeletions = DiskStore.load([UUID: Date].self, key: Self.tombstonesKey) ?? [:]
    }

    /// 保存当前窗口（TabManager）为命名工作区。同名覆盖（=更新）。
    @discardableResult
    func save(name: String, tabManager: TabManager) -> Workspace {
        var savedTabs: [SavedTab] = []
        tabManager.appendSessionTabs(into: &savedTabs, force: true)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? Self.fallbackName : trimmedName
        let workspace = Workspace(
            id: UUID(),
            name: resolvedName,
            session: SavedSession(tabs: savedTabs, selectedIndex: tabManager.selectedIndex,
                                  profileID: tabManager.profileID),
            savedAt: Date())
        workspaces.removeAll { $0.name.lowercased() == resolvedName.lowercased() }
        workspaces.insert(workspace, at: 0)
        persist()
        return workspace
    }

    func remove(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        pendingDeletions[id] = Date()   // 显式删除 → 同步墓碑
        persist()
        persistTombstones()
    }

    /// 同步裁决后清已应用墓碑（冲突回包 = 服务端已裁决，同平铺域口径）。
    func clearPendingDeletions(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { pendingDeletions[id] = nil }
        persistTombstones()
    }

    /// 同步写回（不进任何本地戳——savedAt 随载荷走；远端墓碑走 removeForSync）。
    func replaceForSync(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        workspaces.insert(workspace, at: 0)
        workspaces.sort { $0.savedAt > $1.savedAt }
        pendingDeletions[workspace.id] = nil   // 远端复活 = 撤销本端墓碑
        persist()
        persistTombstones()
    }

    func removeForSync(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        pendingDeletions[id] = nil
        persist()
        persistTombstones()
    }

    /// 恢复：新建 TabManager 装载工作区标签并成为当前窗口内容——由调用方
    /// （ContentView 的 restore 变体）决定装载进新窗口还是当前窗口。
    /// 这里只提供数据；装载复用 TabManager.restoreSession 的 apply 路径。
    func workspace(named name: String) -> Workspace? {
        workspaces.first { $0.name.lowercased() == name.lowercased() }
    }

    private func persist() {
        DiskStore.save(workspaces, key: Self.storageKey)
    }

    private func persistTombstones() {
        DiskStore.save(pendingDeletions, key: Self.tombstonesKey)
    }

    private static let fallbackName = "Workspace"
}
