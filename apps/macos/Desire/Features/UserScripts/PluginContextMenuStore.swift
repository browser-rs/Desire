import Combine
import Foundation

/// 插件注册的右键菜单项（contextMenus.create）。持久化——Chrome 语义：
/// contextMenus 注册一次后跨重启存活（Desire 里 background 每次启动重放
/// onInstalled → 重新 create，本表按 (pluginID, menuID) **upsert** 幂等）。
@MainActor
final class PluginContextMenuStore: ObservableObject {
    static let shared = PluginContextMenuStore()
    private init() { load() }

    struct Item: Codable, Identifiable {
        /// 复合 id（插件 + 菜单项），持久化与去重用。
        var id: String { pluginID.uuidString + "/" + menuID }
        let pluginID: UUID
        /// 扩展语义的菜单项 id（contextMenus.create 的 props.id）。
        let menuID: String
        var title: String
        /// "page" / "link" / "image" / "selection"（其余忽略）。
        var contexts: [String]
    }

    @Published private(set) var items: [Item] = []

    private let saveKey = "plugin-context-menus"

    /// contextMenus.create → upsert（同 (pluginID, menuID) 覆盖——Chrome 对
    /// 重复 id 报错，Desire 幂等覆盖以支持 background 每次启动重放注册）。
    func upsert(pluginID: UUID, menuID: String, title: String, contexts: [String]) {
        let supported = ["page", "link", "image", "selection"]
        let matched = contexts.filter { supported.contains($0) }
        guard !menuID.isEmpty, !matched.isEmpty else { return }
        items.removeAll { $0.pluginID == pluginID && $0.menuID == menuID }
        items.append(Item(pluginID: pluginID, menuID: menuID, title: title, contexts: matched))
        save()
    }

    func remove(pluginID: UUID, menuID: String) {
        items.removeAll { $0.pluginID == pluginID && $0.menuID == menuID }
        save()
    }

    func removeAll(pluginID: UUID) {
        items.removeAll { $0.pluginID == pluginID }
        save()
    }

    /// 插件被停用/卸载时其菜单项不应出现（保留注册数据，过滤在读取侧）。
    func visibleItems(enabledPluginIDs: Set<UUID>) -> [Item] {
        items.filter { enabledPluginIDs.contains($0.pluginID) }
    }

    private func load() {
        items = DiskStore.load([Item].self, key: saveKey) ?? []
    }

    private func save() {
        DiskStore.save(items, key: saveKey)
    }
}
