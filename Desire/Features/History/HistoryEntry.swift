import Foundation

struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let url: String
    let title: String
    let timestamp: Date
}
