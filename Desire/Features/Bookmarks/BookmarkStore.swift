import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
class BookmarkStore: ObservableObject {
    @Published var bookmarks: [Bookmark] = []
    private let saveKey = "desire.bookmarks"

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
        save()
    }

    func update(_ bookmark: Bookmark) {
        _ = bookmarks.update(id: bookmark.id) { $0 = bookmark }
        save()
    }

    func contains(url: String) -> Bool {
        allBookmarks.contains { $0.url == url }
    }

    func find(url: String) -> Bookmark? {
        bookmarks.find { $0.url == url }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }

    private func seedDefaults() {
        bookmarks = [
            .folder(title: "常用网站", children: [
                .leaf(title: "GitHub", url: "https://github.com"),
                .leaf(title: "Stack Overflow", url: "https://stackoverflow.com"),
            ]),
            .leaf(title: "Hacker News", url: "https://news.ycombinator.com"),
        ]
        save()
    }

    // MARK: - Import / Export

    func exportToHTML() {
        let panel = NSSavePanel()
        panel.title = "导出书签"
        panel.nameFieldStringValue = "bookmarks.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = generateBookmarksHTML(bookmarks)
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    func importFromHTML() {
        let panel = NSOpenPanel()
        panel.title = "导入书签"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url,
              let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = parseBookmarksHTML(html)
        guard !parsed.isEmpty else { return }
        bookmarks = parsed
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
        var items: [Bookmark] = []
        var stack: [(UUID, [Bookmark])] = []
        var currentID: UUID?
        let lines = html.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<DT><H3") {
                let title = extractText(from: trimmed) ?? "文件夹"
                let id = UUID()
                let folder = Bookmark.folder(title: title)
                if let parent = currentID {
                    stack.append((parent, []))
                }
                currentID = id
                items.append(folder)
            } else if trimmed.hasPrefix("<DT><A HREF") {
                let url = extractAttribute(trimmed, attr: "HREF") ?? ""
                let title = extractText(from: trimmed) ?? url
                let bm = Bookmark.leaf(title: title, url: url)
                if let cid = currentID, let idx = items.firstIndex(where: { $0.id == cid }) {
                    var folder = items[idx]
                    folder.children.append(bm)
                    items[idx] = folder
                } else {
                    items.append(bm)
                }
            } else if trimmed == "</DL><p>" || trimmed == "</DL>" {
                currentID = stack.popLast()?.0
            }
        }
        return items
    }
}

private func extractText(from line: String) -> String? {
    guard let start = line.firstIndex(of: ">") else { return nil }
    let after = line[line.index(after: start)...]
    guard let end = after.firstIndex(of: "<") else { return nil }
    return String(after[..<end]).trimmingCharacters(in: .whitespaces)
}

private func extractAttribute(_ line: String, attr: String) -> String? {
    guard let range = line.range(of: "\(attr)=\"") else { return nil }
    let after = line[range.upperBound...]
    guard let end = after.firstIndex(of: "\"") else { return nil }
    return String(after[..<end])
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
