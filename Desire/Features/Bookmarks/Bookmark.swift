import Foundation

struct Bookmark: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String?
    var children: [Bookmark]

    var isFolder: Bool { url == nil }
    var isLeaf: Bool { url != nil }

    static func leaf(title: String, url: String) -> Bookmark {
        Bookmark(id: UUID(), title: title, url: url, children: [])
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
}
