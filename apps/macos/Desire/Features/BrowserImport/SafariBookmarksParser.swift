import Foundation

/// Safari `Bookmarks.plist` 解析。
///
/// 结构：根 dict 的 `WebBookmarks` 是 list；节点用 `WebBookmarkType` 区分
/// `WebBookmarkTypeList`（`Children`）与 `WebBookmarkTypeLeaf`
/// （`URLString` + `URIDictionary.title`）。只保留 http/https。
nonisolated enum SafariBookmarksParser {
    static func parse(plist data: Data) throws -> [Bookmark] {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw BrowserImportError.malformed("Bookmarks.plist is not a property list")
        }
        let top = (root["WebBookmarks"] as? [[String: Any]]) ?? []
        var result: [Bookmark] = []
        for node in top {
            let title = (node["Title"] as? String) ?? ""
            let friendly: String = switch title {
            case "BookmarksBar": "Bookmarks Bar"
            case "BookmarksMenu": "Bookmarks Menu"
            case "com.apple.ReadingList": "Reading List"
            default: title
            }
            if let list = parseList(node, fallbackTitle: friendly) {
                result.append(list)
            } else if let leaf = parseLeaf(node) {
                result.append(leaf)
            }
        }
        return result
    }

    private static func parseList(_ node: [String: Any], fallbackTitle: String) -> Bookmark? {
        let type = (node["WebBookmarkType"] as? String) ?? ""
        guard type == "WebBookmarkTypeList" || type == "WebBookmarkTypeProxy" else { return nil }
        let children = ((node["Children"] as? [[String: Any]]) ?? []).compactMap { child in
            parseList(child, fallbackTitle: (child["Title"] as? String) ?? "Folder")
                ?? parseLeaf(child)
        }
        guard !children.isEmpty else { return nil }
        let title = ((node["Title"] as? String) ?? fallbackTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Bookmark.folder(title: title.isEmpty ? fallbackTitle : title, children: children)
    }

    private static func parseLeaf(_ node: [String: Any]) -> Bookmark? {
        let type = (node["WebBookmarkType"] as? String) ?? ""
        guard type == "WebBookmarkTypeLeaf" else { return nil }
        guard let raw = (node["URLString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let scheme = URLComponents(string: raw)?.scheme?.lowercased(),
            scheme == "http" || scheme == "https" else { return nil }
        let uri = node["URIDictionary"] as? [String: Any]
        let title = ((uri?["title"] as? String) ?? (node["Title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Bookmark.leaf(title: title.isEmpty ? raw : title, url: raw)
    }
}
