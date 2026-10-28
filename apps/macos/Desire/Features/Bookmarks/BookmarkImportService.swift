import AppKit
import Foundation
import UniformTypeIdentifiers

struct BookmarkImportService {

    enum ImportSource: String, CaseIterable, Identifiable {
        case safari
        case chrome
        case firefox
        case html
        case json
        case csv

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Chrome"
            case .firefox: "Firefox"
            case .html: "HTML File…"
            case .json: "JSON File…"
            case .csv: "CSV File…"
            }
        }

        var icon: String {
            switch self {
            case .safari: "safari"
            case .chrome: "chrome"
            case .firefox: "firefox"
            case .html: "doc.text"
            case .json: "curlybraces.square"
            case .csv: "tablecells"
            }
        }
    }

    static func importBookmarks(from source: ImportSource) -> [Bookmark]? {
        switch source {
        case .safari:
            return importFromSafari()
        case .chrome:
            return importFromChrome()
        case .firefox:
            return importFromFirefox()
        case .html:
            return importFromHTML()
        case .json:
            return importFromLightFormat(json: true)
        case .csv:
            return importFromLightFormat(json: false)
        }
    }

    // MARK: - 轻量格式（v0.8.17：与 0.8.16 导出对偶）

    private static func importFromLightFormat(json: Bool) -> [Bookmark]? {
        let panel = NSOpenPanel()
        panel.title = String(localized: json ? "Select History JSON File" : "Select Bookmarks CSV File")
        panel.allowedContentTypes = [json ? .json : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let rows: [(title: String, url: String, folder: String)]
        if json {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["bookmarks"] as? [[String: Any]] else { return nil }
            rows = list.compactMap { row in
                guard let link = row["url"] as? String else { return nil }
                return (row["title"] as? String ?? "", link, row["folder"] as? String ?? "")
            }
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let table = SpreadsheetReader.parseDelimited(text, delimiter: ",")
            guard let header = table.first, header.count >= 4 else { return nil }
            rows = table.dropFirst().compactMap { row in
                guard row.count >= 4, !row[1].isEmpty else { return nil }
                return (row[0], row[1], row[2])
            }
        }
        // folder 路径（"A/B"）重建嵌套目录。
        func folderNode(_ path: [String]) -> Bookmark {
            Bookmark(id: UUID(), title: path.last ?? "", url: nil, children: [])
        }
        var rootChildren: [Bookmark] = []
        func descend(_ container: inout [Bookmark], path: [String], item: Bookmark) {
            guard !path.isEmpty else {
                container.append(item)
                return
            }
            let head = path[0]
            if let index = container.firstIndex(where: { $0.isFolder && $0.title == head }) {
                descend(&container[index].children, path: Array(path.dropFirst()), item: item)
            } else {
                var node = folderNode([head])
                descend(&node.children, path: Array(path.dropFirst()), item: item)
                container.append(node)
            }
        }
        for row in rows {
            let segments = row.folder.split(separator: "/").map(String.init)
            let leaf = Bookmark(id: UUID(), title: row.title, url: row.url, children: [])
            descend(&rootChildren, path: segments, item: leaf)
        }
        guard !rootChildren.isEmpty else { return nil }
        return rootChildren
    }

    // MARK: - Safari

    private static func importFromSafari() -> [Bookmark]? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Safari Bookmarks File")
        panel.message = String(localized: "Navigate to ~/Library/Safari/ and select Bookmarks.plist")
        panel.directoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Safari")
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return parseSafariBookmarks(plist)
    }

    private static func parseSafariBookmarks(_ plist: [String: Any]) -> [Bookmark] {
        guard let children = plist["Children"] as? [[String: Any]] else { return [] }
        return parseSafariChildren(children)
    }

    private static func parseSafariChildren(_ items: [[String: Any]]) -> [Bookmark] {
        var result: [Bookmark] = []
        for item in items {
            if let uri = item["URLString"] as? String, let title = item["Title"] as? String {
                result.append(.leaf(title: title, url: uri))
            } else if let title = item["Title"] as? String,
                      let children = item["Children"] as? [[String: Any]] {
                let folder = Bookmark.folder(title: title, children: parseSafariChildren(children))
                result.append(folder)
            } else if let children = item["Children"] as? [[String: Any]] {
                result.append(contentsOf: parseSafariChildren(children))
            }
        }
        return result
    }

    // MARK: - Chrome

    private static func importFromChrome() -> [Bookmark]? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Chrome Bookmarks File")
        panel.message = String(localized: "Navigate to Chrome's profile folder and select Bookmarks")
        panel.directoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Application Support/Google/Chrome/Default")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseChromeBookmarks(json)
    }

    private static func parseChromeBookmarks(_ json: [String: Any]) -> [Bookmark]? {
        guard let roots = json["roots"] as? [String: Any] else { return nil }
        var result: [Bookmark] = []
        for (_, value) in roots {
            guard let dict = value as? [String: Any] else { continue }
            if let children = dict["children"] as? [[String: Any]] {
                result.append(contentsOf: parseChromeChildren(children))
            }
        }
        return result
    }

    private static func parseChromeChildren(_ items: [[String: Any]]) -> [Bookmark] {
        var result: [Bookmark] = []
        for item in items {
            guard let type = item["type"] as? String else { continue }
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if type == "url", let url = item["url"] as? String {
                result.append(.leaf(title: name.isEmpty ? url : name, url: url))
            } else if type == "folder", let children = item["children"] as? [[String: Any]] {
                let folder = Bookmark.folder(title: name.isEmpty ? String(localized: "Folder") : name,
                                              children: parseChromeChildren(children))
                result.append(folder)
            }
        }
        return result
    }

    // MARK: - Firefox

    private static func importFromFirefox() -> [Bookmark]? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Firefox Bookmarks File")
        panel.message = String(localized: "In Firefox, use \"Library → Bookmarks → Import and Backup → Export Bookmarks to HTML\"")
        panel.directoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Application Support/Firefox")
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
              let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseHTMLBookmarks(html)
    }

    // MARK: - HTML (reuse from BookmarkStore logic)

    private static func importFromHTML() -> [Bookmark]? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Bookmarks from HTML")
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
              let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseHTMLBookmarks(html)
    }

    /// HTML 书签文件解析（Netscape 格式）。**实现已移入 `BookmarkHTMLParser`**
    /// （Foundation-only、进单测 harness）；这里保留薄封装供面板与桥调用。
    static func parseHTMLBookmarks(_ html: String) -> [Bookmark] {
        BookmarkHTMLParser.parse(html)
    }
}
