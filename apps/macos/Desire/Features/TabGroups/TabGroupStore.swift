import Combine
import Foundation

@MainActor
class TabGroupStore: ObservableObject {
    @Published var groups: [TabGroup] = []

    private let storageKey = "desire.tabGroups"

    init() { load() }

    func create(name: String, colorIndex: Int = 0) -> TabGroup {
        let group = TabGroup(id: UUID(), name: name, colorIndex: colorIndex, tabIds: [])
        groups.append(group)
        save()
        return group
    }

    /// 改名（v23 智能体工具 renameTabGroup 用；v0.7.18 起 UI 入口齐备：
    /// 顶栏胶囊/折叠胶囊与侧栏行的右键「重命名分组…」都汇到这里）。
    func rename(_ id: UUID, to newName: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[idx].name = trimmed
        save()
    }

    func addTab(_ tabId: UUID, to groupId: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        for i in groups.indices { groups[i].tabIds.remove(tabId) }
        groups[idx].tabIds.insert(tabId)
        save()
    }

    func removeTab(_ tabId: UUID, from groupId: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].tabIds.remove(tabId)
        save()
    }

    func removeTabFromAll(_ tabId: UUID) {
        for i in groups.indices { groups[i].tabIds.remove(tabId) }
        save()
    }

    func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    /// 一键整理/撤销的快照（v0.8.0）。
    func snapshot() -> [TabGroup] { groups }

    func replaceAll(_ snapshot: [TabGroup]) {
        groups = snapshot
        save()
    }

    /// 整组挂起/恢复（v0.8.10）：组内全部标签设为挂起态（当前选中标签
    /// 跳过——它正在渲染）。挂起动作由 TabManager 提供（组存储不依赖它）。
    func suspendGroup(_ id: UUID, suspend: (UUID) -> Void) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        for tabID in groups[idx].tabIds { suspend(tabID) }
    }

    func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].isCollapsed = collapsed
        save()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        setCollapsed(id, !groups[i].isCollapsed)
    }

    func group(for tabId: UUID) -> TabGroup? {
        groups.first { $0.tabIds.contains(tabId) }
    }

    private func save() {
        DiskStore.save(groups, key: storageKey)
    }

    private func load() {
        if let decoded = DiskStore.load([TabGroup].self, key: storageKey) {
            groups = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([TabGroup].self, from: data) {
            groups = decoded
            save()
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }
}
