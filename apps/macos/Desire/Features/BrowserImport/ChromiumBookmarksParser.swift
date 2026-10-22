import Foundation

/// Chromium（Chrome / Edge / Brave / Arc）`Bookmarks` JSON 解析。
///
/// 结构：`{ "roots": { "bookmark_bar": node, "other": node, "synced": node } }`，
/// node = `{type: "url"|"folder", name, url, children}`。只保留 http/https
/// （`chrome://`、`javascript:` 导入进来也打不开）。
nonisolated enum ChromiumBookmarksParser {
    static func parse(data: Data) throws -> [Bookmark] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserImportError.malformed("Bookmarks is not valid JSON")
        }
        guard let roots = root["roots"] as? [String: Any] else {
            throw BrowserImportError.malformed("Bookmarks has no roots")
        }
        let sections: [(key: String, title: String)] = [
            ("bookmark_bar", "Bookmarks Bar"),
            ("other", "Other Bookmarks"),
            ("synced", "Mobile Bookmarks"),
        ]
        var result: [Bookmark] = []
        for section in sections {
            guard let node = roots[section.key] as? [String: Any] else { continue }
            // 用 section 节点自己的 children，不要再套一层它的文件夹名
            // （否则会得到 "Bookmarks Bar" → "Bar" → 条目 的双层文件夹）。
            let children = (node["children"] as? [[String: Any]] ?? []).flatMap(parseNode)
            if !children.isEmpty {
                result.append(Bookmark.folder(title: section.title, children: children))
            }
        }
        return result
    }

    private static func parseNode(_ node: [String: Any]) -> [Bookmark] {
        let type = (node["type"] as? String) ?? ""
        let title = ((node["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "url" {
            guard let url = (node["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  isWebURL(url) else { return [] }
            return [Bookmark.leaf(title: title.isEmpty ? url : title, url: url)]
        }
        if type == "folder" {
            let children = (node["children"] as? [[String: Any]] ?? [])
                .flatMap(parseNode)
            guard !children.isEmpty else { return [] }
            return [Bookmark.folder(title: title.isEmpty ? "Folder" : title,
                                    children: children)]
        }
        return []
    }

    private static func isWebURL(_ raw: String) -> Bool {
        guard let scheme = URLComponents(string: raw)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}
