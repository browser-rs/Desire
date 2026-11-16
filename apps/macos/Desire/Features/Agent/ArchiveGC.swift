import Foundation

/// **落盘生命周期 GC**（v0.8.61 批 2，Foundation-only 进 tests/run.sh）。
/// 归档与转存只进不出会无限增长——两条纯逻辑阈值判定 + 一条截断：
/// · 归档（conversation-<id>.archive.json 的 [AgentMessage]）：单份超过
///   `maxBytes` 时从**最老消息**开始丢弃，保留最近的内容并在头部插一行
///   截断标注（最近的归档轮次信息价值最高）；
/// · 转存目录（tool-results/）：按"容量上限 + 最老文件年龄"双阈值清——
///   先删超龄文件（按修改时间），仍超容量再从最老文件继续删。
nonisolated enum ArchiveGC {

    /// 归档单份上限（字节；AgentMessage JSON 的粗粒度安全网）。
    static let maxArchiveBytes = 10 * 1_000_000
    /// 转存目录容量上限 / 文件最老年龄（天）。
    static let spillCapacityBytes = 1_000_000_000
    static let spillMaxAgeDays = 30

    /// 归档截断：序列化后超限时从最老消息丢起。返回 (截断后的数组, 是否发生截断)。
    /// 空数组/未超限原样返回。截断后在**头部**插一条 system 标注（归档的消费方
    /// 是 recallConversation——标注让"为什么找不到更早的"可解释）。
    static func truncateArchive(_ messages: [AgentMessage], maxBytes: Int = maxArchiveBytes)
        -> (messages: [AgentMessage], truncated: Bool) {
        func serialized(_ msgs: [AgentMessage]) -> Int {
            (try? JSONEncoder().encode(msgs))?.count ?? 0
        }
        guard serialized(messages) > maxBytes, !messages.isEmpty else {
            return (messages, false)
        }
        var kept = messages
        while serialized(kept) > maxBytes && kept.count > 1 {
            kept.removeFirst()
        }
        let note = AgentMessage(
            role: .system,
            content: "[archive truncated] 最早的归档轮次因超出容量上限被清除；以上是保留的较近归档。")
        kept.insert(note, at: 0)
        return (kept, true)
    }

    /// 转存目录清理候选：先按年龄（modificationDate 早于 cutoff）列删除集；
    /// 若删完总容量仍超上限，再从最老文件继续补删。返回待删路径（按最老优先）。
    static func spillCleanupTargets(_ entries: [(path: String, size: Int, modified: Date)],
                                    capacityBytes: Int = spillCapacityBytes,
                                    maxAgeDays: Int = spillMaxAgeDays,
                                    now: Date = Date()) -> [String] {
        guard !entries.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        var remaining: [(path: String, size: Int, modified: Date)] = []
        var targets: [String] = []
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            if entry.modified < cutoff {
                targets.append(entry.path)
            } else {
                remaining.append(entry)
            }
        }
        var total = remaining.reduce(0) { $0 + $1.size }
        if total <= capacityBytes { return targets }
        for entry in remaining {
            targets.append(entry.path)
            total -= entry.size
            if total <= capacityBytes { break }
        }
        return targets
    }
}
