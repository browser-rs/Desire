import Foundation

/// 存储保留策略的**纯判定**（v0.8.80 批 6）：会话/归档按天数、缓存按容量 LRU。
/// IO 在 `StorageMaintenance`，这里只决定删哪些（harness 直测）。
nonisolated enum StorageRetention {
    struct FileEntry: Equatable {
        let path: String
        let bytes: Int
        let modified: Date
    }

    /// 超过保留天数的文件（retentionDays <= 0 = 不删）。
    static func expired(_ entries: [FileEntry], retentionDays: Int,
                        now: Date = Date()) -> [String] {
        guard retentionDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return entries.filter { $0.modified < cutoff }.map(\.path)
    }

    /// LRU：总量超过预算时，从最旧开始删到预算内。
    static func lruTargets(_ entries: [FileEntry], maxBytes: Int) -> [String] {
        let total = entries.reduce(0) { $0 + $1.bytes }
        guard total > maxBytes else { return [] }
        var remaining = total
        var targets: [String] = []
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            targets.append(entry.path)
            remaining -= entry.bytes
            if remaining <= maxBytes { break }
        }
        return targets
    }
}
