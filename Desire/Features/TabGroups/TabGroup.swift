import Foundation

struct TabGroup: Identifiable, Codable {
    let id: UUID
    var name: String
    var colorIndex: Int
    var tabIds: Set<UUID>
    /// Collapsed groups render as a single pill in the tab strip.
    var isCollapsed: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, colorIndex, tabIds, isCollapsed
    }

    init(id: UUID, name: String, colorIndex: Int, tabIds: Set<UUID>, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.tabIds = tabIds
        self.isCollapsed = isCollapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
        tabIds = try container.decode(Set<UUID>.self, forKey: .tabIds)
        // Older session/group files predate the flag.
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
}

let tabGroupColorNames: [String] = [
    "red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"
]
