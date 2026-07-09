import Combine
import Foundation

@MainActor
class ConversationStore: ObservableObject {
    @Published var conversations: [Conversation] = []

    private var storageURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("me.siwi.Desire/conversations")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        loadAll()
    }

    func loadAll() {
        let fm = FileManager.default
        let dir = storageURL
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            conversations = []
            return
        }
        var result: [Conversation] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conv = try? JSONDecoder().decode(Conversation.self, from: data) else { continue }
            result.append(conv)
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        conversations = result
    }

    func save(_ conversation: Conversation) {
        let url = storageURL.appendingPathComponent("\(conversation.id.uuidString).json")
        guard let data = try? JSONEncoder().encode(conversation) else { return }
        try? data.write(to: url, options: .atomic)
        loadAll()
    }

    func delete(_ id: UUID) {
        let url = storageURL.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        loadAll()
    }

    func rename(_ id: UUID, to title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conv = conversations[idx]
        conv.title = title
        save(conv)
    }

    func conversation(for id: UUID) -> Conversation? {
        let url = storageURL.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let conv = try? JSONDecoder().decode(Conversation.self, from: data) else { return nil }
        return conv
    }

    func create(title: String = "New Conversation") -> Conversation {
        Conversation(id: UUID(), title: title, createdAt: Date(), updatedAt: Date(), messages: [])
    }
}
