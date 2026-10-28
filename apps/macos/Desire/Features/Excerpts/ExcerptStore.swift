import Combine
import Foundation

/// 摘录库存储（v0.8.17 融合旗舰）：阅读高亮/PDF 批注/网页划选的统一沉淀。
/// DiskStore 持久化（500ms 防抖，测试断言前 sleep 1）、上限 500 条（FIFO 淘汰）；
/// 同步口径照 JobRecord——pendingDeletions 显式墓碑 + updatedAt LWW +
/// HMAC 反查（SyncStore adapter 负责，本类只提供 upsert/remove/clear 三个口）。
@MainActor
final class ExcerptStore: ObservableObject {

    static let shared = ExcerptStore()

    static let cap = 500
    private let storeKey = "excerpts"

    @Published private(set) var excerpts: [Excerpt] = []   // 新在前
    /// 待推墓碑（realID → deletedAt）；服务端裁决后清除。
    @Published private(set) var pendingDeletions: [String: Date] = [:]

    private init() {
        excerpts = DiskStore.load([Excerpt].self, key: storeKey) ?? []
        if let dict = DiskStore.load([String: Date].self, key: storeKey + ".pendingDeletions") {
            pendingDeletions = dict
        }
        excerpts.sort { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        DiskStore.save(excerpts, key: storeKey)
        DiskStore.save(pendingDeletions, key: storeKey + ".pendingDeletions")
    }

    // MARK: - 收录

    /// 收录一条；同来源同内容（去重键命中）只刷新 updatedAt 不新增。
    /// 返回是否新增（false = 去重命中已存在）。
    @discardableResult
    func add(kind: Excerpt.Kind, title: String, source: String,
             content: String, note: String? = nil) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = Excerpt(kind: kind, title: title, source: source, content: trimmed).dedupeKey
        if let index = excerpts.firstIndex(where: { $0.dedupeKey == key }) {
            excerpts[index].updatedAt = Date()
            persist()
            return false
        }
        let excerpt = Excerpt(kind: kind, title: title, source: source,
                              content: trimmed, note: note)
        excerpts.insert(excerpt, at: 0)
        if excerpts.count > Self.cap {
            // FIFO 淘汰最老的（数组按 createdAt 降序，尾部即最老）。
            let dropped = excerpts.suffix(from: Self.cap)
            for item in dropped { pendingDeletions[item.id.uuidString] = Date() }
            excerpts = Array(excerpts.prefix(Self.cap))
        }
        persist()
        return true
    }

    func updateNote(id: UUID, note: String?) {
        guard let index = excerpts.firstIndex(where: { $0.id == id }) else { return }
        excerpts[index].note = note
        excerpts[index].updatedAt = Date()
        persist()
    }

    func remove(id: UUID) {
        guard let index = excerpts.firstIndex(where: { $0.id == id }) else { return }
        excerpts.remove(at: index)
        pendingDeletions[id.uuidString] = Date()
        persist()
    }

    /// 一键清空：全部记墓碑（清空 = 逐条 tombstone 既有口径）。
    func clearAll() {
        let now = Date()
        for excerpt in excerpts { pendingDeletions[excerpt.id.uuidString] = now }
        excerpts.removeAll()
        persist()
    }

    // MARK: - 查询 / 导出

    func filtered(query: String, kind: Excerpt.Kind?) -> [Excerpt] {
        excerpts.filter { excerpt in
            (kind == nil || excerpt.kind == kind) && excerpt.matches(query)
        }
    }

    /// Markdown 笔记本：按来源分节（保持收录时间序），首行总标题。
    func exportMarkdown(query: String = "", kind: Excerpt.Kind? = nil) -> String {
        let items = filtered(query: query, kind: kind)
        guard !items.isEmpty else { return "" }
        var out = "# Excerpts\n\n"
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        out += "> \(formatter.string(from: Date())) · \(items.count) item(s)\n\n"
        var bySource: [(source: String, title: String, items: [Excerpt])] = []
        for excerpt in items {
            if let index = bySource.firstIndex(where: { $0.source == excerpt.source }) {
                bySource[index].items.append(excerpt)
            } else {
                bySource.append((excerpt.source, excerpt.title, [excerpt]))
            }
        }
        for group in bySource {
            out += Excerpt.markdownSection(title: group.title, source: group.source, items: group.items)
        }
        return out
    }

    // MARK: - 同步口（SyncStore adapter 专用；命名对齐 JobStore）

    func upsertForSync(_ excerpt: Excerpt) {
        guard let index = excerpts.firstIndex(where: { $0.id == excerpt.id }) else {
            excerpts.insert(excerpt, at: 0)
            if excerpts.count > Self.cap {
                excerpts = Array(excerpts.prefix(Self.cap))
            }
            persist()
            return
        }
        excerpts[index] = excerpt
        excerpts.sort { $0.createdAt > $1.createdAt }
        persist()
    }

    func removeForSync(id: UUID) {
        guard let index = excerpts.firstIndex(where: { $0.id == id }) else { return }
        excerpts.remove(at: index)
        persist()
    }

    func clearPendingDeletions(serverIDs: Set<UUID>) {
        guard !serverIDs.isEmpty else { return }
        for id in serverIDs { pendingDeletions.removeValue(forKey: id.uuidString) }
        persist()
    }
}
