import Foundation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [AgentMessage]
}
