import Combine
import Foundation

/// 工具栏布局（v0.8.83）：DiskStore 持久化，Toolbar 与设置页共同观察。
/// 只存"顺序 + 隐藏集合"；新增按钮在 `load` 时自动并入默认顺序，旧配置
/// 不会因为版本升级丢按钮。
@MainActor
final class ToolbarCustomizationStore: ObservableObject {
    static let shared = ToolbarCustomizationStore()

    @Published private(set) var order: [ToolbarItem]
    @Published private(set) var hidden: Set<ToolbarItem>

    private let key = "toolbarCustomization"

    private struct Layout: Codable {
        var order: [ToolbarItem]
        var hidden: [ToolbarItem]
    }

    private init() {
        order = ToolbarItem.defaultOrder
        hidden = ToolbarItem.defaultHidden
        load()
    }

    func isVisible(_ item: ToolbarItem) -> Bool {
        !hidden.contains(item)
    }

    func visibleOrder() -> [ToolbarItem] {
        order.filter { !hidden.contains($0) }
    }

    func toggle(_ item: ToolbarItem) {
        if hidden.contains(item) {
            hidden.remove(item)
        } else {
            hidden.insert(item)
        }
        save()
    }

    func setHidden(_ items: Set<ToolbarItem>) {
        hidden = items
        save()
    }

    func setOrder(_ items: [ToolbarItem]) {
        order = Self.normalizedOrder(items)
        save()
    }

    func moveUp(_ item: ToolbarItem) {
        guard let index = order.firstIndex(of: item), index > 0 else { return }
        order.swapAt(index, index - 1)
        save()
    }

    func moveDown(_ item: ToolbarItem) {
        guard let index = order.firstIndex(of: item), index < order.count - 1 else { return }
        order.swapAt(index, index + 1)
        save()
    }

    func reset() {
        order = ToolbarItem.defaultOrder
        hidden = ToolbarItem.defaultHidden
        save()
    }

    var isCustomized: Bool {
        order != ToolbarItem.defaultOrder || hidden != ToolbarItem.defaultHidden
    }

    /// 桥诊断（`/diag/toolbar`）：顺序、隐藏项、实际可见项一次看全。
    func diagnostics() -> [String: Any] {
        [
            "ok": true,
            "order": order.map(\.rawValue),
            "hidden": ToolbarItem.allCases.filter { hidden.contains($0) }.map(\.rawValue),
            "visible": visibleOrder().map(\.rawValue),
            "fixedVisible": ToolbarItem.fixedItems.filter { isVisible($0) }.map(\.rawValue),
            "customized": isCustomized
        ]
    }

    private static func normalizedOrder(_ proposed: [ToolbarItem]) -> [ToolbarItem] {
        var seen = Set<ToolbarItem>()
        var result: [ToolbarItem] = []
        for item in proposed where item.isReorderable && seen.insert(item).inserted {
            result.append(item)
        }
        // 旧配置缺项（版本新增）自动补到末尾，保持用户已有顺序。
        for item in ToolbarItem.defaultOrder where !seen.contains(item) {
            result.append(item)
        }
        return result
    }

    private func load() {
        guard let layout = DiskStore.load(Layout.self, key: key) else { return }
        order = Self.normalizedOrder(layout.order)
        hidden = Set(layout.hidden.filter { ToolbarItem.allCases.contains($0) })
    }

    private func save() {
        DiskStore.save(Layout(order: order, hidden: ToolbarItem.allCases.filter { hidden.contains($0) }),
                       key: key)
    }
}
