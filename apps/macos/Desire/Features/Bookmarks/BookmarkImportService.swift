import AppKit
import Foundation
import UniformTypeIdentifiers

struct BookmarkImportService {

    enum ImportSource: String, CaseIterable, Identifiable {
        case safari
        case chrome
        case firefox
        case html

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Chrome"
            case .firefox: "Firefox"
            case .html: "HTML File…"
            }
        }

        var icon: String {
            switch self {
            case .safari: "safari"
            case .chrome: "chrome"
            case .firefox: "firefox"
            case .html: "doc.text"
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
        }
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
