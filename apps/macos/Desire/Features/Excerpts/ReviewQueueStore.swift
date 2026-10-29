import Combine
import Foundation

/// 复习队列（v0.8.22）：把摘录库变成**间隔重复**——1/3/7/21/60 天五档；
/// "记得"升一档、"忘了"回到第 1 档（明天再见）。只存排程（摘录 id + 档位 +
/// 到期时间），内容仍以 ExcerptStore 为唯一真相；删掉的摘录由 `sync` 清理。
///
/// 本机数据，不随同步（排程是个人节奏，跨设备会互相打架）。
nonisolated struct ReviewEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID        // = Excerpt.id
    var stage: Int      // 0...4
    var dueAt: Date
    var lastReviewedAt: Date?
    var lapses: Int
}

@MainActor
final class ReviewQueueStore: ObservableObject {
    static let shared = ReviewQueueStore()

    @Published private(set) var entries: [ReviewEntry] = []

    private static let key = "review-queue"
    /// 1 / 3 / 7 / 21 / 60 天。
    static let intervals: [TimeInterval] = [1, 3, 7, 21, 60].map { $0 * 86_400 }

    private init() {
        entries = DiskStore.load([ReviewEntry].self, key: Self.key) ?? []
    }

    /// 与摘录库对齐：新摘录今天到期入队，已删除的移出。
    func sync(with excerpts: [Excerpt]) {
        let alive = Set(excerpts.map(\.id))
        var changed = false
        if entries.contains(where: { !alive.contains($0.id) }) {
            entries.removeAll { !alive.contains($0.id) }
            changed = true
        }
        let known = Set(entries.map(\.id))
        for excerpt in excerpts where !known.contains(excerpt.id) {
            entries.append(ReviewEntry(id: excerpt.id, stage: 0, dueAt: Date(),
                                       lastReviewedAt: nil, lapses: 0))
            changed = true
        }
        if changed { persist() }
    }

    /// 到期条目（按到期时间正序）。
    var due: [ReviewEntry] {
        let now = Date()
        return entries.filter { $0.dueAt <= now }.sorted { $0.dueAt < $1.dueAt }
    }

    func grade(id: UUID, remembered: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        entry.lastReviewedAt = Date()
        if remembered {
            entry.stage = min(entry.stage + 1, Self.intervals.count - 1)
        } else {
            entry.stage = 0
            entry.lapses += 1
        }
        entry.dueAt = Date().addingTimeInterval(Self.intervals[entry.stage])
        entries[index] = entry
        persist()
    }

    /// 跳过：不动档位，明天再来（避免"今天不想看"把节奏打乱）。
    func snooze(id: UUID, days: Int = 1) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].dueAt = Date().addingTimeInterval(TimeInterval(max(1, days)) * 86_400)
        persist()
    }

    func reset() {
        entries.removeAll()
        persist()
    }

    func payload() -> [String: Any] {
        let dueIDs = Set(due.map(\.id))
        return [
            "total": entries.count,
            "due": dueIDs.count,
            "entries": entries.sorted { $0.dueAt < $1.dueAt }.map { entry -> [String: Any] in
                [
                    "id": entry.id.uuidString,
                    "stage": entry.stage,
                    "dueAt": entry.dueAt.timeIntervalSince1970,
                    "due": dueIDs.contains(entry.id),
                    "lapses": entry.lapses,
                    "lastReviewedAt": entry.lastReviewedAt?.timeIntervalSince1970 ?? 0,
                ]
            },
        ]
    }

    private func persist() {
        DiskStore.save(entries, key: Self.key)
    }
}
