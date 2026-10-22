import Foundation

/// 历史导入合并（纯逻辑，进 harness）。
///
/// 语义：同一 URL 不新增行；`visitCount` 相加、时间取较新、标题缺则补齐，
/// 最后按时间倒序裁剪到 `cap`。与 `HistoryStore.addEntry` 的"每站一行"一致。
nonisolated enum HistoryImportMerge {
    struct Result {
        var entries: [HistoryEntry]
        var added: Int
        var skipped: Int
    }

    static func merge(existing: [HistoryEntry],
                      imported: [ImportedHistoryEntry],
                      cap: Int = 500) -> Result {
        var byURL: [String: HistoryEntry] = [:]
        var order: [String] = []
        for entry in existing {
            let key = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if byURL[key] == nil { order.append(key) }
            byURL[key] = entry
        }
        var added = 0
        var skipped = 0
        for item in imported {
            let key = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if var current = byURL[key] {
                current.visitCount += max(1, item.visitCount)
                if item.timestamp > current.timestamp {
                    current.timestamp = item.timestamp
                }
                if current.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || current.title == current.url {
                    current.title = item.title
                }
                current.updatedAt = Date()
                byURL[key] = current
                skipped += 1
            } else {
                byURL[key] = HistoryEntry(
                    id: UUID(), url: item.url, title: item.title,
                    timestamp: item.timestamp, updatedAt: Date(),
                    visitCount: max(1, item.visitCount))
                order.append(key)
                added += 1
            }
        }
        var merged = order.compactMap { byURL[$0] }
        merged.sort { $0.timestamp > $1.timestamp }
        if merged.count > cap { merged = Array(merged.prefix(cap)) }
        return Result(entries: merged, added: added, skipped: skipped)
    }
}
