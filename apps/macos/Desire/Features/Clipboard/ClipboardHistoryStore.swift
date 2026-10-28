import AppKit
import Combine
import Foundation

/// 剪贴板历史（v0.8.19 旗舰）：轮询 changeCount，文本/URL/文件路径
/// 复制记录 30 条、24h TTL。隐私口径：密码面板复制走 suppressNext()
/// 不入库；超长文本（>10k）不入库；点击回灌走同一条抑制（不自我记录）。
@MainActor
final class ClipboardHistoryStore: ObservableObject {

    static let shared = ClipboardHistoryStore()

    struct Entry: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case url, path, text
        }

        var id: UUID
        var text: String
        var kind: Kind
        var capturedAt: Date
    }

    static let cap = 30
    static let ttl: TimeInterval = 24 * 3600
    private static let storeKey = "clipboard-history"
    private nonisolated static let maxRecordLength = 10_000

    @Published private(set) var entries: [Entry] = []   // 新在前
    /// 待推墓碑（同步第十四域，v0.8.20）——删除/淘汰/清空都记。
    @Published private(set) var pendingDeletions: [String: Date] = [:]
    /// 一条抑制：密码复制/回灌等"这次别记"。
    private var suppressNext = false
    private var lastChangeCount: Int
    private var pollTimer: Timer?

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        entries = ClipboardHistoryStore.prune(DiskStore.load([Entry].self, key: Self.storeKey) ?? [])
        if let dict = DiskStore.load([String: Date].self, key: Self.storeKey + ".pendingDeletions") {
            pendingDeletions = dict
        }
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    /// 密码面板等敏感复制调用：接下来这次剪贴板变化不记录。
    func suppressNextCapture() {
        suppressNext = true
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        if suppressNext {
            suppressNext = false
            return
        }
        // 文本优先；无文本再试文件 URL（拷贝文件得到的是 file URL 类型）。
        var text = pasteboard.string(forType: .string) ?? ""
        if text.isEmpty, let fileURL = pasteboard.string(forType: .fileURL) {
            text = fileURL
        }
        record(text: text)
    }

    /// 入库判定与分类（纯逻辑，桥/测试可复用）。返回将写入的 Entry。
    nonisolated static func makeEntry(text: String, now: Date = Date(),
                                      fileExists: @autoclosure () -> Bool = false) -> Entry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxRecordLength else { return nil }
        let kind: Entry.Kind
        if let url = URL(string: trimmed), url.scheme != nil,
           url.scheme == "http" || url.scheme == "https" || url.scheme == "file",
           url.host != nil || url.scheme == "file" {
            kind = .url
        } else if trimmed.hasPrefix("/") && fileExists() {
            kind = .path
        } else {
            kind = .text
        }
        return Entry(id: UUID(), text: trimmed, kind: kind, capturedAt: now)
    }

    private func record(text: String) {
        guard var entry = Self.makeEntry(text: text, fileExists: FileManager.default.fileExists(atPath: text)) else {
            return
        }
        // 与最新一条相同 = 刷新时间戳（去重不堆叠）。
        if let first = entries.first, first.text == entry.text {
            entry.id = first.id
            entry.capturedAt = Date()
            entries[0] = entry
            persist()
            return
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.cap {
            for dropped in entries.suffix(from: Self.cap) {
                pendingDeletions[dropped.id.uuidString] = Date()
            }
            entries = Array(entries.prefix(Self.cap))
        }
        let expired = Set(Self.prune(entries).map(\.id))
        for gone in entries where !expired.contains(gone.id) {
            pendingDeletions[gone.id.uuidString] = Date()
        }
        entries = Self.prune(entries)
        persist()
    }

    /// 回灌剪贴板（面板点击）：抑制自我记录。
    func copyBack(_ entry: Entry) {
        suppressNext = true
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        pendingDeletions[id.uuidString] = Date()
        persist()
    }

    func clearAll() {
        let now = Date()
        for entry in entries { pendingDeletions[entry.id.uuidString] = now }
        entries.removeAll()
        persist()
    }

    // MARK: - 同步口（SyncStore adapter 专用；命名对齐 ExcerptStore）

    func upsertForSync(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
            if entries.count > Self.cap {
                entries = Array(entries.prefix(Self.cap))
            }
        }
        persist()
    }

    func removeForSync(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clearPendingDeletions(serverIDs: Set<UUID>) {
        guard !serverIDs.isEmpty else { return }
        for id in serverIDs { pendingDeletions.removeValue(forKey: id.uuidString) }
        persist()
    }

    private func persist() {
        DiskStore.save(entries, key: Self.storeKey)
        DiskStore.save(pendingDeletions, key: Self.storeKey + ".pendingDeletions")
    }

    private static func prune(_ items: [Entry]) -> [Entry] {
        let cutoff = Date().addingTimeInterval(-ttl)
        return items.filter { $0.capturedAt >= cutoff }
    }
}
