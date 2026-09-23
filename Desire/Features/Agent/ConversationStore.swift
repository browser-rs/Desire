import Combine
import Foundation

@MainActor
class ConversationStore: ObservableObject {
    @Published var conversations: [Conversation] = []

    /// Legacy on-disk directory used before this store was routed through
    /// `DiskStore`. Read once at init for migration, then ignored.
    private let legacyDirectory: URL = {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("me.siwi.Desire/conversations")
    }()

    init() {
        loadAll()
    }

    /// Rebuilds the in-memory list from disk. Only used at init and after
    /// `delete`; `save` updates the list in place instead (avoids re-reading
    /// every conversation file on every save, which used to stall the AI
    /// agent loop as conversations accumulated).
    func loadAll() {
        var result: [Conversation] = []
        let fm = FileManager.default

        // Primary: DiskStore-managed files under Application Support/Desire/storage.
        let dir = DiskStore.directory
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                let name = file.deletingPathExtension().lastPathComponent
                guard name.hasPrefix("conversation-"),
                      let data = try? Data(contentsOf: file),
                      let conv = try? JSONDecoder().decode(Conversation.self, from: data) else { continue }
                result.append(conv)
            }
        }

        // One-time migration from the legacy directory. If the legacy folder
        // exists and still holds files, import them through DiskStore and then
        // remove the legacy folder so this branch is a no-op next launch.
        if result.isEmpty {
            let migrated = migrateLegacyIfNeeded()
            result.append(contentsOf: migrated)
        }

        result.sort { $0.updatedAt > $1.updatedAt }
        conversations = result
    }

    /// Saves `conversation` via the debounced off-main `DiskStore`, then upserts
    /// the in-memory list in place — no full reload.
    func save(_ conversation: Conversation) {
        DiskStore.save(conversation, key: "conversation-\(conversation.id.uuidString)")
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = conversation
        } else {
            conversations.append(conversation)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ id: UUID) {
        delete([id])
    }

    /// 批量删除（历史列表多选后用）。
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            DiskStore.remove(key: "conversation-\(id.uuidString)")
        }
        conversations.removeAll { ids.contains($0.id) }
    }

    func rename(_ id: UUID, to title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conv = conversations[idx]
        conv.title = title
        save(conv)
    }

    /// Returns the conversation for `id`, preferring the in-memory list (which
    /// is always up to date with the latest `save`) and falling back to disk.
    func conversation(for id: UUID) -> Conversation? {
        if let conv = conversations.first(where: { $0.id == id }) {
            return conv
        }
        return DiskStore.load(Conversation.self, key: "conversation-\(id.uuidString)")
    }

    func create(title: String = "New Conversation") -> Conversation {
        Conversation(id: UUID(), title: title, createdAt: Date(), updatedAt: Date(), messages: [])
    }

    /// Reads any conversations from the pre-DiskStore directory, writes them
    /// through DiskStore, and removes the legacy folder. Returns the migrated
    /// conversations so the caller can include them in the initial list.
    private func migrateLegacyIfNeeded() -> [Conversation] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var migrated: [Conversation] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conv = try? JSONDecoder().decode(Conversation.self, from: data) else { continue }
            DiskStore.save(conv, key: "conversation-\(conv.id.uuidString)")
            migrated.append(conv)
        }
        if !migrated.isEmpty {
            try? fm.removeItem(at: legacyDirectory)
        }
        return migrated
    }
}
