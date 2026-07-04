import Combine
import Foundation

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
}
