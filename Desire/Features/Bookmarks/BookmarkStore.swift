import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
class BookmarkStore: ObservableObject {
    @Published var bookmarks: [Bookmark] = []
    private let saveKey = "bookmarks"
    /// Profile 作用域（0.3.5）：nil = 默认桶；切换时保存当前 → 加载新桶
    /// （种子/legacy 迁移只属于默认桶，作用域桶为空即空）。
    private var scopeID: UUID?
    private var scopedKey: String {
        guard let scopeID else { return saveKey }
        return saveKey + "." + scopeID.uuidString
    }
    /// Legacy UserDefaults key — read once during migration, then deleted.
    private let legacySaveKey = "desire.bookmarks"

    /// URL index of all leaf bookmarks, maintained incrementally so
    /// `contains(url:)` is O(1) instead of flattening the whole tree on every
    /// call (it ran 3× per Toolbar render, per keystroke in the address bar).
    private var leafURLs: Set<String> = []

    /// Flattened, pre-lowercased leaf entries for cheap address-bar matching.
    /// Rebuilt alongside `leafURLs`. Lets `AddressSuggestionsModel.build` scan
    /// bookmarks per keystroke without flattening the tree or calling
    /// `.lowercased()` on each item each time.
    private(set) var leafEntries: [LeafEntry] = []

    /// A lowercase-indexed bookmark leaf for suggestion matching.
    struct LeafEntry {
        let title: String
        let url: String
        let titleLower: String
        let urlLower: String
    }

    init() {
        load()
        if bookmarks.isEmpty { seedDefaults() }
    }

    var allBookmarks: [Bookmark] {
        bookmarks.flatMap { $0.flattened() }.filter { $0.0.isLeaf }.map(\.0)
    }

    func add(title: String, url: String, parentID: UUID? = nil) {
        let bookmark = Bookmark.leaf(title: title, url: url)
        if let parentID {
            _ = bookmarks.update(id: parentID) { $0.children.append(bookmark) }
        } else {
            bookmarks.append(bookmark)
        }
        // Rebuild (not just leafURLs.insert): leafEntries feeds address-bar
        // suggestion matching — without this, a freshly added bookmark only
        // started suggesting after a relaunch.
        rebuildURLIndex()
        save()
    }

    func addFolder(title: String, parentID: UUID? = nil) {
        let folder = Bookmark.folder(title: title)
        if let parentID {
            _ = bookmarks.update(id: parentID) { $0.children.append(folder) }
        } else {
            bookmarks.append(folder)
        }
        save()
    }

    func remove(_ bookmark: Bookmark) {
        _ = bookmarks.remove(id: bookmark.id)
        rebuildURLIndex()
        save()
    }

    func update(_ bookmark: Bookmark) {
        _ = bookmarks.update(id: bookmark.id) { $0 = bookmark }
        rebuildURLIndex()
        save()
    }

    func contains(url: String) -> Bool {
        leafURLs.contains(url)
    }

    func find(url: String) -> Bookmark? {
        bookmarks.find { $0.url == url }
    }

    private func load() {
        // Primary: DiskStore (debounced, off-main).
        if let decoded = DiskStore.load([Bookmark].self, key: saveKey) {
            bookmarks = decoded
            rebuildURLIndex()
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: legacySaveKey),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = decoded
            rebuildURLIndex()
            save()
            UserDefaults.standard.removeObject(forKey: legacySaveKey)
        }
    }

    func save() {
        DiskStore.save(bookmarks, key: scopedKey)
    }

    /// AppState.applyProfile 驱动（0.3.5）。
    func applyScope(profileID: UUID?) {
        guard scopeID != profileID else { return }
        save()
        scopeID = profileID
        bookmarks = DiskStore.load([Bookmark].self, key: scopedKey) ?? []
        rebuildURLIndex()
    }

    func saveImported(_ newBookmarks: [Bookmark]) {
        bookmarks.append(contentsOf: newBookmarks)
        rebuildURLIndex()
        save()
    }

    /// Rebuilds `leafURLs` and `leafEntries` from the current tree. Called
    /// after load and after mutations that can change many URLs at once
    /// (remove, update, import).
    private func rebuildURLIndex() {
        let leaves = allBookmarks.compactMap { $0.url }
        leafURLs = Set(leaves)
        leafEntries = allBookmarks.map {
            LeafEntry(
                title: $0.title,
                url: $0.url ?? "",
                titleLower: $0.title.lowercased(),
                urlLower: ($0.url ?? "").lowercased()
            )
        }
    }

    private func seedDefaults() {
        bookmarks = [
            .folder(title: String(localized: "Common Sites"), children: [
                .leaf(title: "GitHub", url: "https://github.com"),
                .leaf(title: "Stack Overflow", url: "https://stackoverflow.com"),
            ]),
            .leaf(title: "Hacker News", url: "https://news.ycombinator.com"),
        ]
        rebuildURLIndex()
        save()
    }

    // MARK: - Import / Export

    func exportToHTML() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Bookmarks")
        panel.nameFieldStringValue = "bookmarks.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = generateBookmarksHTML(bookmarks)
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    func importFromHTML() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Bookmarks")
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
              let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = parseBookmarksHTML(html)
        guard !parsed.isEmpty else { return }
        bookmarks = parsed
        rebuildURLIndex()
        save()
    }

    private func generateBookmarksHTML(_ items: [Bookmark], indent: Int = 0) -> String {
        let ind = String(repeating: "    ", count: indent)
        var html = "\(ind)<DL><p>\n"
        for item in items {
            if item.isLeaf, let url = item.url {
                let title = item.title.htmlEscaped
                let href = url.htmlEscaped
                html += "\(ind)    <DT><A HREF=\"\(href)\">\(title)</A>\n"
            } else {
                html += "\(ind)    <DT><H3>\(item.title.htmlEscaped)</H3>\n"
                html += generateBookmarksHTML(item.children, indent: indent + 1)
            }
        }
        html += "\(ind)</DL><p>\n"
        return html
    }

    private func parseBookmarksHTML(_ html: String) -> [Bookmark] {
        var stack: [Bookmark] = []
        var root: [Bookmark] = []

        func addToCurrent(_ item: Bookmark) {
            if let top = stack.last, top.isFolder {
                stack[stack.count - 1].children.append(item)
            } else {
                root.append(item)
            }
        }

        var searchRange = html.startIndex..<html.endIndex
        while let dtRange = html.range(of: "<DT>", options: [.caseInsensitive], range: searchRange) {
            searchRange = dtRange.upperBound..<html.endIndex

            let rest = html[searchRange]
            if rest.hasPrefix("<A ") || rest.hasPrefix("<A\t") || rest.hasPrefix("<A\n") {
                guard let hrefStart = rest.range(of: "HREF=\"", options: [.caseInsensitive]) else { continue }
                let urlStart = hrefStart.upperBound
                guard let urlEnd = rest[urlStart...].firstIndex(of: "\"") else { continue }
                let url = String(rest[urlStart..<urlEnd])

                let afterURL = rest[urlEnd...]
                guard let closeTag = afterURL.range(of: "</A>", options: [.caseInsensitive]) else { continue }
                let titleStart = afterURL.firstIndex(of: ">") ?? urlEnd
                let titleEnd = closeTag.lowerBound
                let title = (titleStart < titleEnd)
                    ? String(afterURL[titleStart..<titleEnd])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
                    : ""

                searchRange = closeTag.upperBound..<html.endIndex
                addToCurrent(Bookmark.leaf(title: title.isEmpty ? url : title, url: url))

            } else if rest.hasPrefix("<H3") || rest.hasPrefix("<H3\t") || rest.hasPrefix("<H3\n") {
                guard let closeTag = rest.range(of: "</H3>", options: [.caseInsensitive]) else { continue }
                let titleStart = rest.firstIndex(of: ">") ?? rest.startIndex
                let titleEnd = closeTag.lowerBound
                let title = (titleStart < titleEnd)
                    ? String(rest[rest.index(after: titleStart)..<titleEnd])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                searchRange = closeTag.upperBound..<html.endIndex
                stack.append(Bookmark.folder(title: title.isEmpty ? String(localized: "Folder") : title))

            } else if rest.hasPrefix("<DL") || rest.hasPrefix("<DL\t") || rest.hasPrefix("<DL\n") {
                guard let dlEnd = rest.range(of: ">") else { continue }
                searchRange = dlEnd.upperBound..<html.endIndex

            } else if rest.hasPrefix("</DL>") || rest.hasPrefix("</DL\t") || rest.hasPrefix("</DL\n") {
                if let folder = stack.popLast() {
                    addToCurrent(folder)
                }
                searchRange = html.index(searchRange.lowerBound, offsetBy: 5)..<html.endIndex
            } else if rest.hasPrefix("<HR") {
                guard let hrEnd = rest.range(of: ">") else { continue }
                searchRange = hrEnd.upperBound..<html.endIndex
            } else if rest.hasPrefix("<META") {
                guard let metaEnd = rest.range(of: ">") else { continue }
                searchRange = metaEnd.upperBound..<html.endIndex
            } else if rest.hasPrefix("<!") {
                guard let commentEnd = rest.range(of: ">") else { continue }
                searchRange = commentEnd.upperBound..<html.endIndex
            } else if rest.hasPrefix("<p>") || rest.hasPrefix("<P>") {
                searchRange = html.index(searchRange.lowerBound, offsetBy: 3)..<html.endIndex
            } else {
                searchRange = html.index(after: searchRange.lowerBound)..<html.endIndex
            }
        }

        for folder in stack.reversed() {
            addToCurrent(folder)
        }
        return root
    }
}

private extension String {
    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
