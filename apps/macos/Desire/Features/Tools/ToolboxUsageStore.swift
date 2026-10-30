import Combine
import Foundation

/// 工具箱的收藏与最近使用（本机 UserDefaults；不随同步走）。
@MainActor
final class ToolboxUsageStore: ObservableObject {
    static let shared = ToolboxUsageStore()

    @Published private(set) var favorites: [String] = []
    @Published private(set) var recents: [String] = []

    private static let favoritesKey = "toolbox.favorites"
    private static let recentsKey = "toolbox.recents"
    private static let recentsLimit = 6

    private init() {
        favorites = UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []
        recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    }

    func isFavorite(_ id: String) -> Bool {
        favorites.contains(id)
    }

    func toggleFavorite(_ id: String) {
        if let index = favorites.firstIndex(of: id) {
            favorites.remove(at: index)
        } else {
            favorites.append(id)
        }
        UserDefaults.standard.set(favorites, forKey: Self.favoritesKey)
    }

    func record(_ id: String) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.recentsLimit {
            recents = Array(recents.prefix(Self.recentsLimit))
        }
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }
}
