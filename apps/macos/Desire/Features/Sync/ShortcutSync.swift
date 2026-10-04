import AppKit
import Foundation

/// 快捷键域的同步适配。ShortcutMapping 依赖 AppKit，进不了纯逻辑测试
/// harness——合并核心复用 Foundation-only 的 FlatSyncMerge（有测试覆盖），
/// 这里只是闭包适配 + 线路载荷。
/// 域语义：无删除（重置 = isCustomized=false 的更新）；每次全量 push 全部映射，
/// 远端"新增的默认命令 id"合并后追加在表尾。
struct ShortcutSyncPayload: Codable, Equatable {
    /// 真实命令 id(线上 client_id 是它的 HMAC)
    var id: String
    var commandName: String
    var keyEquivalent: String
    var modifierFlags: UInt
    var isCustomized: Bool
    var category: String
}

enum ShortcutSync {
    static func payload(_ mapping: ShortcutMapping) -> ShortcutSyncPayload {
        ShortcutSyncPayload(
            id: mapping.id,
            commandName: mapping.commandName,
            keyEquivalent: mapping.keyEquivalent,
            modifierFlags: mapping.modifierFlags,
            isCustomized: mapping.isCustomized,
            category: mapping.category.rawValue
        )
    }

    static func flatten(_ mappings: [ShortcutMapping]) -> [SyncWireItem<ShortcutSyncPayload>] {
        mappings.map { syncWire(id: $0.id, updatedAt: $0.updatedAt, payload: payload($0)) }
    }

    static func merge(
        base: [ShortcutMapping], remote: [SyncWireItem<ShortcutSyncPayload>]
    ) -> [ShortcutMapping] {
        FlatSyncMerge.merge(
            base: base,
            remote: remote,
            idOf: { $0.id },
            updatedAtOf: { $0.updatedAt },
            make: { _, payload, at in
                guard let category = ShortcutMapping.Category(rawValue: payload.category) else {
                    return nil
                }
                return ShortcutMapping(
                    id: payload.id,
                    commandName: payload.commandName,
                    keyEquivalent: payload.keyEquivalent,
                    modifierFlags: payload.modifierFlags,
                    isCustomized: payload.isCustomized,
                    category: category,
                    updatedAt: at
                )
            },
            update: { mapping, payload, at in
                mapping.commandName = payload.commandName
                mapping.keyEquivalent = payload.keyEquivalent
                mapping.modifierFlags = payload.modifierFlags
                mapping.isCustomized = payload.isCustomized
                if let category = ShortcutMapping.Category(rawValue: payload.category) {
                    mapping.category = category
                }
                mapping.updatedAt = at
            }
        )
    }
}
