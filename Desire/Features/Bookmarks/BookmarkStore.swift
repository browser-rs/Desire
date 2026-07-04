import Combine
import Foundation

@MainActor
class BookmarkStore: ObservableObject {
    @Published var bookmarks: [Bookmark] = []
    private let saveKey = "desire.bookmarks"

    init() {
        load()
    }

    func add(title: String, url: String) {
        let bookmark = Bookmark(id: UUID(), title: title, url: url)
        bookmarks.insert(bookmark, at: 0)
        save()
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    func update(_ bookmark: Bookmark) {
        guard let i = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[i] = bookmark
        save()
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
}
