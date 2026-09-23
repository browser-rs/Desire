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

    // MARK: - 检索（`searchConversations` / `readConversation` 工具用）

    struct SearchHit {
        let id: UUID
        let title: String
        let updatedAt: Date
        let messageCount: Int
        /// 命中处前后的一小段原文（给模型足够上下文，但不撑爆它的窗口）。
        let snippet: String
        let matchedIn: String
    }

    /// 关键词检索历史对话（标题 + 正文，大小写不敏感）——与历史面板里的搜索同一口径。
    /// 供 Agent 工具与桥端点共用；`excluding` 用来排除当前对话（它已在模型上下文里）。
    func search(_ query: String, limit: Int = 5, excluding excludedID: UUID? = nil) -> [SearchHit] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 2 else { return [] }
        var hits: [SearchHit] = []
        for conv in conversations where conv.id != excludedID {
            let titleHit = conv.title.localizedCaseInsensitiveContains(key)
            let bodyHit = conv.messages.contains { $0.content?.localizedCaseInsensitiveContains(key) == true }
            guard titleHit || bodyHit else { continue }
            hits.append(SearchHit(
                id: conv.id,
                title: conv.title,
                updatedAt: conv.updatedAt,
                messageCount: conv.messages.count,
                snippet: snippet(in: conv, key: key),
                matchedIn: titleHit ? "title" : "message"
            ))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// 命中处前后各留 `radius` 个字符。
    private func snippet(in conv: Conversation, key: String, radius: Int = 140) -> String {
        guard let message = conv.messages.first(where: { $0.content?.localizedCaseInsensitiveContains(key) == true }),
              let text = message.content,
              let range = text.range(of: key, options: .caseInsensitive) else {
            return String(conv.title.prefix(120))
        }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        return prefix + text[start..<end].replacingOccurrences(of: "\n", with: " ") + suffix
    }

    /// 把一条对话序列化成紧凑的、带角色标记的文本（长对话按 `maxChars` 截断）。
    func transcript(id: UUID, maxChars: Int = 12_000) -> String? {
        guard let conv = conversations.first(where: { $0.id == id }) else { return nil }
        var lines: [String] = ["# \(conv.title)"]
        var used = 0
        for message in conv.messages {
            let role: String
            switch message.role {
            case .user: role = "User"
            case .assistant: role = "Assistant"
            case .tool: role = "Tool"
            case .system: continue
            }
            var body = message.content ?? ""
            if let calls = message.toolCalls, !calls.isEmpty {
                body += (body.isEmpty ? "" : " ") + calls.map { "[\($0.function.name)]" }.joined(separator: " ")
            }
            guard !body.isEmpty else { continue }
            if used + body.count > maxChars {
                lines.append("… (\(conv.messages.count) messages total, truncated)")
                break
            }
            used += body.count
            lines.append("\(role): \(body)")
        }
        return lines.joined(separator: "\n\n")
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
