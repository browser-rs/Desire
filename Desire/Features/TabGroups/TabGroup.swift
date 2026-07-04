import Foundation

struct TabGroup: Identifiable, Codable {
    let id: UUID
    var name: String
    var colorIndex: Int
    var tabIds: Set<UUID>
}

let tabGroupColorNames: [String] = [
    "red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"
]
