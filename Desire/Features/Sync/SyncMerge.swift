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
                    id: node.id,
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
    /// 父节点在本批次中晚于子节点出现（跨设备时钟乱序）时，子节点先进孤儿队列，
    /// 批次结束后归位——游标已推进，不会再来第二次。
    static func merge(
        base: [Bookmark],
        remote: [SyncWireItem<BookmarkSyncPayload>]
    ) -> [Bookmark] {
        var tree = base
        let items = remote.sorted { a, b in
            if a.clientUpdatedAt != b.clientUpdatedAt { return a.clientUpdatedAt < b.clientUpdatedAt }
            return a.clientId < b.clientId
        }
        var orphans: [(node: Bookmark, parentID: UUID?, sort: Int)] = []
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
                if !insertNode(node, parentID: payload.parentID, sort: payload.sort, into: &tree) {
                    orphans.append((node, payload.parentID, payload.sort))
                }
            }
        }
        placeOrphans(&tree, &orphans)
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
            _ = insertNode(updated, parentID: originalParent, sort: payload.sort, into: &tree)
        } else {
            _ = insertNode(updated, parentID: payload.parentID, sort: payload.sort, into: &tree)
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
    ) -> Bool {
        if let parentID {
            var inserted = false
            _ = tree.update(id: parentID) { parent in
                let index = min(max(sort, 0), parent.children.count)
                parent.children.insert(node, at: index)
                inserted = true
            }
            return inserted
        }
        tree.insert(node, at: min(max(sort, 0), tree.count))
        return true
    }

    /// 孤儿归位：父节点在本批次晚出现时重试挂回；链式依赖（父也是孤儿）用
    /// 多轮直到无进展；父始终没出现的兜底挂根。
    private static func placeOrphans(
        _ tree: inout [Bookmark], _ orphans: inout [(node: Bookmark, parentID: UUID?, sort: Int)]
    ) {
        var progress = true
        while progress && !orphans.isEmpty {
            progress = false
            var remaining: [(node: Bookmark, parentID: UUID?, sort: Int)] = []
            for (node, parentID, sort) in orphans {
                if let parentID, findNode(tree, id: parentID) != nil {
                    _ = insertNode(node, parentID: parentID, sort: sort, into: &tree)
                    progress = true
                } else {
                    remaining.append((node, parentID, sort))
                }
            }
            orphans = remaining
        }
        for (node, _, sort) in orphans {
            tree.insert(node, at: min(max(sort, 0), tree.count))
        }
    }
}

// MARK: - 平铺列表域（快拨 / 阅读列表 / 快捷键）

/// 平铺列表域的合并核心，与书签树同一套 LWW 规则：远端旧 → 忽略；
/// 同刻且非删除 → 忽略；**同刻删除 → 应用（收敛）**；远端新 → 盖写/追加。
/// 元素适配走闭包，让核心保持 Foundation-only 可进 tests/run.sh
/// （ShortcutMapping 依赖 AppKit，经这套闭包间接复用）。
enum FlatSyncMerge {
    static func merge<Element, P: Codable>(
        base: [Element],
        remote: [SyncWireItem<P>],
        idOf: (Element) -> String,
        updatedAtOf: (Element) -> Date?,
        make: (String, P, Date) -> Element?,
        update: (inout Element, P, Date) -> Void
    ) -> [Element] {
        var items = base
        let sorted = remote.sorted { a, b in
            if a.clientUpdatedAt != b.clientUpdatedAt { return a.clientUpdatedAt < b.clientUpdatedAt }
            return a.clientId < b.clientId
        }
        for item in sorted {
            let remoteAt = item.clientUpdatedAt
            if let idx = items.firstIndex(where: { idOf($0) == item.clientId }) {
                let localAt = updatedAtOf(items[idx]) ?? .distantPast
                if localAt > remoteAt { continue }
                if localAt == remoteAt && !(item.deleted ?? false) { continue }
                if item.deleted ?? false {
                    items.remove(at: idx)
                } else if let payload = item.payload {
                    update(&items[idx], payload, remoteAt)
                }
            } else if !(item.deleted ?? false), let payload = item.payload,
                      let created = make(item.clientId, payload, remoteAt) {
                items.append(created)
            }
        }
        return items
    }
}

/// 便捷构造：平铺条目 → 线路条目（id 用客户端稳定字符串；UUID 域传 uuidString）。
func syncWire<P>(
    id: String, updatedAt: Date?, deleted: Bool = false, payload: P
) -> SyncWireItem<P> {
    SyncWireItem(
        clientId: id,
        clientUpdatedAt: updatedAt ?? .distantPast,
        deleted: deleted,
        payload: payload,
        updatedAt: nil
    )
}

struct QuickDialSyncPayload: Codable, Equatable {
    var id: UUID
    var title: String
    var url: String
    var icon: String
    var sort: Int
}

enum QuickDialSync {
    static func payload(_ dial: QuickDial) -> QuickDialSyncPayload {
        QuickDialSyncPayload(id: dial.id, title: dial.title, url: dial.url, icon: dial.icon,
                             sort: dial.sort)
    }

    /// 合并后按 sort 重排（列表序 = payload.sort，与 Store 的重编号约定一致）。
    /// 线上 client_id 是 HMAC,真实 id 以 payload.id 为准。
    static func merge(
        base: [QuickDial], remote: [SyncWireItem<QuickDialSyncPayload>]
    ) -> [QuickDial] {
        let merged = FlatSyncMerge.merge(
            base: base,
            remote: remote,
            idOf: { $0.id.uuidString },
            updatedAtOf: { $0.updatedAt },
            make: { _, payload, at in
                QuickDial(id: payload.id, title: payload.title, url: payload.url,
                          icon: payload.icon, sort: payload.sort, updatedAt: at)
            },
            update: { dial, payload, at in
                dial.title = payload.title
                dial.url = payload.url
                dial.icon = payload.icon
                dial.sort = payload.sort
                dial.updatedAt = at
            }
        )
        return merged.sorted { $0.sort < $1.sort }
    }
}

struct ReadingListSyncPayload: Codable, Equatable {
    var id: UUID
    var title: String
    var url: String
    /// naive UTC（SyncDate 编解码）
    var savedDate: Date
    var isRead: Bool
}

// MARK: - Agent 记忆域（事实 / 摘要 / 画像）

/// Agent 记忆的同步载荷（密文内部结构，三选一）。
enum AgentMemoryItem: Codable, Equatable {
    case fact(MemoryFact)
    case summary(ConversationSummary)
    case profile(UserProfile)
}

/// Agent 记忆的一次远端变更：realID = 事实/摘要 id 或 "profile"；
/// item = nil 时表示 tombstone（删除）。
struct AgentMemoryChange {
    var realID: String
    var clientUpdatedAt: Date
    var deleted: Bool
    var item: AgentMemoryItem?
}

/// Agent 记忆的可同步快照（AgentMemoryStore.archive 的值拷贝）。
struct AgentMemorySnapshot: Codable, Equatable {
    var profile: UserProfile
    var profileUpdatedAt: Date?
    var facts: [MemoryFact]
    var summaries: [ConversationSummary]
}

enum AgentMemorySync {
    /// 逐条 LWW 应用远端变更（按 clientUpdatedAt 升序处理，新的覆盖旧的）：
    /// - 事实/摘要：存在且本地不旧 → 忽略；否则盖写/插入；
    /// - 删除：按 realID 移除（无论当前是否本机存在，幂等）；
    /// - 画像：与 profileUpdatedAt 比较 LWW。
    static func apply(
        base: AgentMemorySnapshot, changes: [AgentMemoryChange]
    ) -> AgentMemorySnapshot {
        var s = base
        let sorted = changes.sorted { a, b in a.clientUpdatedAt < b.clientUpdatedAt }
        for change in sorted {
            if change.deleted {
                // tombstone 同样走 LWW:本地时间戳更新则忽略这次删除
                if let idx = s.facts.firstIndex(where: { $0.id.uuidString == change.realID }) {
                    if s.facts[idx].updatedAt <= change.clientUpdatedAt {
                        s.facts.remove(at: idx)
                    }
                    continue
                }
                if let idx = s.summaries.firstIndex(where: { $0.id.uuidString == change.realID }),
                   s.summaries[idx].createdAt <= change.clientUpdatedAt {
                    s.summaries.remove(at: idx)
                }
                continue
            }
            guard let item = change.item else { continue }
            switch item {
            case .fact(let fact):
                if let idx = s.facts.firstIndex(where: { $0.id == fact.id }) {
                    if s.facts[idx].updatedAt <= change.clientUpdatedAt {
                        var updated = fact
                        updated.updatedAt = change.clientUpdatedAt
                        s.facts[idx] = updated
                    }
                } else {
                    var inserted = fact
                    inserted.updatedAt = change.clientUpdatedAt
                    s.facts.insert(inserted, at: 0)
                }
            case .summary(let summary):
                if let idx = s.summaries.firstIndex(where: { $0.id == summary.id }) {
                    if s.summaries[idx].createdAt <= change.clientUpdatedAt {
                        var updated = summary
                        updated.createdAt = change.clientUpdatedAt
                        s.summaries[idx] = updated
                    }
                } else {
                    var inserted = summary
                    inserted.createdAt = change.clientUpdatedAt
                    s.summaries.insert(inserted, at: 0)
                }
            case .profile(let profile):
                if (s.profileUpdatedAt ?? .distantPast) <= change.clientUpdatedAt {
                    s.profile = profile
                    s.profileUpdatedAt = change.clientUpdatedAt
                }
            }
        }
        return s
    }
}

enum ReadingListSync {
    static func payload(_ item: ReadingListItem) -> ReadingListSyncPayload {
        ReadingListSyncPayload(id: item.id, title: item.title, url: item.url,
                               savedDate: item.savedDate, isRead: item.isRead)
    }

    static func merge(
        base: [ReadingListItem], remote: [SyncWireItem<ReadingListSyncPayload>]
    ) -> [ReadingListItem] {
        FlatSyncMerge.merge(
            base: base,
            remote: remote,
            idOf: { $0.id.uuidString },
            updatedAtOf: { $0.updatedAt },
            make: { _, payload, at in
                ReadingListItem(id: payload.id, title: payload.title, url: payload.url,
                                savedDate: payload.savedDate, isRead: payload.isRead,
                                updatedAt: at)
            },
            update: { item, payload, at in
                item.title = payload.title
                item.url = payload.url
                item.savedDate = payload.savedDate
                item.isRead = payload.isRead
                item.updatedAt = at
            }
        )
    }
}
