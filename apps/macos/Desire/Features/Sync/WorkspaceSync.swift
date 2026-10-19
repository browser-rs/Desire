import Foundation

/// 工作区云同步（v0.7.25，第十域，默认关）：**每工作区一文档**的 KV 域——
/// client_id = HMAC(工作区 UUID)，payload = {名称 + 标签清单 + 选中位 + 保存时间}。
/// 与白板域同构（整文档 LWW），两点差异：
/// ① **sessionState（页面还原 blob）在 collect 时剥掉**——那是机器本地的
///    WebKit 状态，跨端还原只会带垃圾；远端回来的标签按 url/pin 重建。
/// ② LWW 时钟 = 载荷内的 savedAt（工作区语义就是"保存时刻"），无独立 updatedTimes。
/// Foundation-only（进 harness）。
nonisolated enum WorkspaceSync {
    /// 标签的**可移植**投影（SavedTab 的机器本地字段不进载荷）。
    struct TabPayload: Codable, Equatable {
        var url: String?
        var isOnNewTabPage: Bool
        var isPinned: Bool
    }

    struct Payload: Codable, Equatable {
        /// 真实工作区 UUID 字符串（密文内部；线上 client_id 是 HMAC）。
        var id: String
        var name: String
        var tabs: [TabPayload]
        var selectedIndex: Int
        var savedAt: Date
    }

    /// 单文档体量护栏（服务端硬顶 256KB；标签清单远小于此，超了整单跳过）。
    static let maxPayloadChars = 180_000

    static func payload(id: String, name: String, tabs: [TabPayload],
                        selectedIndex: Int, savedAt: Date) -> Payload? {
        let payload = Payload(id: id, name: name, tabs: tabs,
                              selectedIndex: selectedIndex, savedAt: savedAt)
        guard let data = try? JSONEncoder().encode(payload),
              data.count <= maxPayloadChars else { return nil }
        return payload
    }

    /// LWW 合并：远端 savedAt **严格新于**本地才盖写（同刻忽略=幂等）；
    /// 墓碑比本地保存新才删（本端在墓碑之后又保存过 → 本端赢，保留并重推）。
    static func apply(base: [String: Payload],
                      remote: [SyncWireItem<Payload>],
                      tombstones: [String: Date]) -> [String: Payload] {
        var boards = base
        for (id, deletedAt) in tombstones {
            guard let local = boards[id] else { continue }
            if local.savedAt > deletedAt { continue }
            boards[id] = nil
        }
        for item in remote.sorted(by: { $0.clientUpdatedAt < $1.clientUpdatedAt }) {
            guard item.deleted != true, let payload = item.payload else { continue }
            if let local = boards[payload.id], local.savedAt >= item.clientUpdatedAt { continue }
            boards[payload.id] = payload
        }
        return boards
    }
}
