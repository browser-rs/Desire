import Foundation

/// 书签树的同步展平/合并（纯逻辑，tests/run.sh 覆盖）。
///
/// 树 ↔ 条目：每个节点一条（parentID + sort 表达结构，children 不进 payload）。
/// 合并仲裁 = `clientUpdatedAt` LWW：本地 `updatedAt` 由 BookmarkStore 在每次
/// 改动时盖戳、加载时归一化（nil 视为 `.distantPast`，只在服务端明确更新时被改写）。
enum BookmarkSync {

    struct FlatItem {
        var id: UUID
        var updatedAt: Date
        var payload: BookmarkSyncPayload
    }

    // MARK: - 树 → 条目（push 用）

    static func flatten(_ tree: [Bookmark]) -> [FlatItem] {
        var out: [FlatItem] = []
        walk(tree, parent: nil, into: &out)
        return out
    }

    private static func walk(_ nodes: [Bookmark], parent: UUID?, into out: inout [FlatItem]) {
        for (index, node) in nodes.enumerated() {
            out.append(FlatItem(
                id: node.id,
                updatedAt: node.updatedAt ?? .distantPast,
                payload: BookmarkSyncPayload(
                    parentID: parent,
                    title: node.title,
                    url: node.url,
                    sort: index
                )
            ))
            walk(node.children, parent: node.id, into: &out)
        }
    }

    // MARK: - 条目 → 合并进本地树（pull 用）

    /// 处理顺序按 `clientUpdatedAt` 升序（老的先应用，新的覆盖其效果）。
    /// 仲裁：本地更新 → 忽略；本地同刻且非删除 → 忽略（内容相同）；
    /// **同刻删除 → 应用**（收敛：避免"服务端 tombstone vs 本地活节点同戳"死循环）。
    static func merge(
        base: [Bookmark],
        remote: [SyncWireItem<BookmarkSyncPayload>]
    ) -> [Bookmark] {
        var tree = base
        let items = remote.sorted { a, b in
            if a.clientUpdatedAt != b.clientUpdatedAt { return a.clientUpdatedAt < b.clientUpdatedAt }
            return a.clientId < b.clientId
        }
        for item in items {
            guard let id = UUID(uuidString: item.clientId) else { continue }
            let remoteAt = item.clientUpdatedAt
            if let local = findNode(tree, id: id) {
                let localAt = local.updatedAt ?? .distantPast
                if localAt > remoteAt { continue }
                if localAt == remoteAt && !(item.deleted ?? false) { continue }
                if item.deleted ?? false {
                    _ = tree.remove(id: id)
                } else if let payload = item.payload {
                    applyRemote(&tree, id: id, payload: payload, at: remoteAt)
                }
            } else if !(item.deleted ?? false), let payload = item.payload {
                var node = Bookmark(id: id, title: payload.title, url: payload.url, children: [])
                node.updatedAt = remoteAt
                insertNode(node, parentID: payload.parentID, sort: payload.sort, into: &tree)
            }
        }
        return tree
    }

    // MARK: - Private

    private static func findNode(_ nodes: [Bookmark], id: UUID) -> Bookmark? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNode(node.children, id: id) { return found }
        }
        return nil
    }

    /// 更新远端胜出的节点：字段盖写 + reparent + sort。摘出整棵子树再插回
    /// （移动文件夹时子孙随行）。目标父是自身或自身子孙（成环）时保持原父。
    private static func applyRemote(
        _ tree: inout [Bookmark], id: UUID, payload: BookmarkSyncPayload, at: Date
    ) {
        guard findNode(tree, id: id) != nil else { return }
        let originalParent = findParentID(tree, childID: id)
        guard let node = tree.remove(id: id) else { return }
        var updated = node
        updated.title = payload.title
        updated.url = payload.url
        updated.updatedAt = at
        let cyclesIntoSelf = payload.parentID == id
            || (payload.parentID != nil && findNode(node.children, id: payload.parentID!) != nil)
        if cyclesIntoSelf {
            insertNode(updated, parentID: originalParent, sort: payload.sort, into: &tree)
        } else {
            insertNode(updated, parentID: payload.parentID, sort: payload.sort, into: &tree)
        }
    }

    private static func findParentID(_ tree: [Bookmark], childID: UUID) -> UUID? {
        for node in tree {
            if node.children.contains(where: { $0.id == childID }) { return node.id }
            if let deep = findParentID(node.children, childID: childID) { return deep }
        }
        return nil
    }

    private static func insertNode(
        _ node: Bookmark, parentID: UUID?, sort: Int, into tree: inout [Bookmark]
    ) {
        if let parentID {
            var inserted = false
            _ = tree.update(id: parentID) { parent in
                let index = min(max(sort, 0), parent.children.count)
                parent.children.insert(node, at: index)
                inserted = true
            }
            // 父节点缺失（远端乱序/本地尚未拉到）：兜底挂根，下次 pull 修正。
            if !inserted {
                tree.insert(node, at: min(max(sort, 0), tree.count))
            }
        } else {
            tree.insert(node, at: min(max(sort, 0), tree.count))
        }
    }
}
