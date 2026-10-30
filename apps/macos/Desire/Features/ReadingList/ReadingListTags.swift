import Foundation

/// 阅读列表标签的纯逻辑（v0.8.25）：归一、解析与匹配（进 harness）。
nonisolated enum ReadingListTags {
    /// 去空白、丢空项、大小写不敏感去重（保留首次出现的写法与顺序）。
    static func normalize(_ raw: [String]) -> [String] {
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

    /// 从输入框文本解析：逗号（中英文）、顿号、分号都可作分隔。
    static func parse(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；")
        return normalize(text.components(separatedBy: separators))
    }

    /// 是否含有某标签（大小写不敏感）。
    static func matches(tags: [String], filter: String) -> Bool {
        guard !filter.isEmpty else { return true }
        let needle = filter.lowercased()
        return tags.contains { $0.lowercased() == needle }
    }

    /// 全部标签（大小写不敏感去重、按字母序）。
    static func all(in tagsLists: [[String]]) -> [String] {
        let merged = normalize(tagsLists.flatMap { $0 })
        return merged.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// 行内编辑：加/删单个标签后的新列表。
    static func toggling(_ tag: String, in tags: [String]) -> [String] {
        let normalizedTag = normalize([tag]).first ?? ""
        guard !normalizedTag.isEmpty else { return tags }
        if tags.contains(where: { $0.lowercased() == normalizedTag.lowercased() }) {
            return tags.filter { $0.lowercased() != normalizedTag.lowercased() }
        }
        return normalize(tags + [normalizedTag])
    }
}
