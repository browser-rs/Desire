import Foundation

/// 书签批量编辑的纯逻辑（v0.8.25）：标签归一/增删与移动合法性（进 harness）。
nonisolated enum BookmarkBatchEdit {
    /// 去空白、丢空项、大小写不敏感去重（保留首次写法）。
    static func normalizeTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// 逗号（中英文）、顿号、分号分隔。
    static func parseTags(_ text: String) -> [String] {
        normalizeTags(text.components(separatedBy: CharacterSet(charactersIn: ",，、;；")))
    }

    static func merged(existing: [String]?, adding: [String]) -> [String]? {
        let result = normalizeTags((existing ?? []) + adding)
        return result.isEmpty ? nil : result
    }

    static func removed(existing: [String]?, removing: [String]) -> [String]? {
        let drop = Set(normalizeTags(removing).map { $0.lowercased() })
        guard !drop.isEmpty else { return existing }
        let result = (existing ?? []).filter { !drop.contains($0.lowercased()) }
        return result.isEmpty ? nil : result
    }

    /// 移动合法性：不能不进文件夹（nil = 根），不能移进自己或自己的子孙；
    /// 目标必须是文件夹。
    static func canMove(_ node: Bookmark, into target: Bookmark?) -> Bool {
        guard let target else { return true }
        guard target.isFolder else { return false }
        if target.id == node.id { return false }
        return !subtreeIDs(node).contains(target.id)
    }

    static func subtreeIDs(_ node: Bookmark) -> Set<UUID> {
        var ids: Set<UUID> = [node.id]
        for child in node.children { ids.formUnion(subtreeIDs(child)) }
        return ids
    }
}
