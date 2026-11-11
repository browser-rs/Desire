import Foundation

nonisolated struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var url: String?
    var children: [Bookmark]
    /// 云同步的 LWW 仲裁戳（每次本地改动由 BookmarkStore 盖戳）。
    /// Optional + 合成 Codable = 旧文件缺键解码为 nil，不会清空数据。
    var updatedAt: Date? = nil
    /// 标签（v0.8.6）：可搜索/可过滤；Optional = 旧文件兼容
    var tags: [String]? = nil

    var isFolder: Bool { url == nil }
    var isLeaf: Bool { url != nil }

    static func leaf(title: String, url: String, tags: [String]? = nil) -> Bookmark {
        Bookmark(id: UUID(), title: title, url: url, children: [], tags: tags)
    }

    static func folder(title: String, children: [Bookmark] = []) -> Bookmark {
        Bookmark(id: UUID(), title: title, url: nil, children: children)
    }
}

extension Bookmark {
    func flattened() -> [(Bookmark, Int)] {
        var result: [(Bookmark, Int)] = []
        flatten(level: 0, into: &result)
        return result
    }

    private func flatten(level: Int, into result: inout [(Bookmark, Int)]) {
        result.append((self, level))
        for child in children {
            child.flatten(level: level + 1, into: &result)
        }
    }
}

extension [Bookmark] {
    func find(where predicate: (Bookmark) -> Bool) -> Bookmark? {
        for b in self {
            if predicate(b) { return b }
            if let found = b.children.find(where: predicate) { return found }
        }
        return nil
    }

    mutating func remove(id: UUID) -> Bookmark? {
        for i in indices {
            if self[i].id == id { return remove(at: i) }
            if let removed = self[i].children.remove(id: id) { return removed }
        }
        return nil
    }

    mutating func update(id: UUID, transform: (inout Bookmark) -> Void) -> Bool {
        for i in indices {
            if self[i].id == id {
                transform(&self[i])
                return true
            }
            if self[i].children.update(id: id, transform: transform) { return true }
        }
        return false
    }

    /// 同层重排（v0.8.53 书签 2.0）：把 id 移到其所在层的 toIndex 位置
    /// （该层其余兄弟的原始下标口径，先摘除再按钳制后的目标位插入）。
    /// 只做同层重排；跨层移动走 BookmarkStore.move(ids:toFolder:)。
    /// 找不到节点 / 目标位就是原位时返回 false，树保持不变。
    mutating func reorder(id: UUID, toIndex: Int) -> Bool {
        // 根层
        if let current = firstIndex(where: { $0.id == id }) {
            let clamped = Swift.min(Swift.max(0, toIndex), count - 1)
            guard clamped != current else { return false }
            let node = remove(at: current)
            insert(node, at: clamped)
            return true
        }
        // 子层
        for i in indices {
            guard let current = self[i].children.firstIndex(where: { $0.id == id }) else {
                continue
            }
            let clamped = Swift.min(Swift.max(0, toIndex), self[i].children.count - 1)
            guard clamped != current else { return false }
            let node = self[i].children.remove(at: current)
            self[i].children.insert(node, at: clamped)
            return true
        }
        return false
    }
}
