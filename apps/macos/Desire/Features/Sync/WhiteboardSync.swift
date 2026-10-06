import Foundation

/// 白板云同步（0.6.8 第九类，默认关）：**每会话一文档**的 KV 域——
/// client_id = HMAC(会话 id)，payload = 整板（密文）。与平铺列表域的差异：
/// ① 文档整体 LWW（块级合并不做——板是创作物，不是状态机）；② image 块的
/// data URI 在 collect 时剥成占位符（截图动辄数百 KB，服务端 payload ≤256KB；
/// 也避免每轮重传大图），apply 时按**块 UUID** 从本地板找同一块回填；
/// ③ 远端墓碑 payload 为 NULL，靠**正向 HMAC 匹配**本地会话 id 落地
/// （拉取侧跨设备删除——平铺域至今没做这件事，白板域是第一个做对的）。
enum WhiteboardSync {
    /// collect 时替换 image 块 content 的占位符（apply 凭它 + 块 UUID 回填）。
    static let imagePlaceholder = "__unsynced-image__"
    /// 单板 payload 的软上限（编码后字节）：超出跳过并日志——服务端硬顶 256KB。
    static let maxPayloadChars = 180_000

    struct Payload: Codable, Equatable {
        /// 真实会话 id（密文内部；线上 client_id 是 HMAC）。
        var conversationId: String
        var title: String
        var blocks: [WhiteboardBlock]
        /// 板级更新时间（= 线上 client_updated_at，双写防口径漂移）。
        var updatedAt: Date
    }

    /// collect：剥图 + 组 payload。返回 nil = 板超限/无戳，本轮跳过（日志由调用方给）。
    static func payload(for spec: WhiteboardSpec, conversationId: String, updatedAt: Date) -> Payload? {
        var blocks = spec.blocks
        for i in blocks.indices where blocks[i].type == WhiteboardBlock.Kind.image {
            blocks[i].content = Self.imagePlaceholder
        }
        let payload = Payload(conversationId: conversationId, title: spec.title,
                              blocks: blocks, updatedAt: updatedAt)
        // 体量护栏：超限整板跳过（绝不静默剥块——半块板比没有更误导）。
        guard JSONEncodeCount(payload) <= maxPayloadChars else { return nil }
        return payload
    }

    /// apply：远端文档 LWW 落地 + 墓碑（正向匹配好的真实会话 id → 时间）落地。
    /// 返回 (板, 戳)；调用方拿它走 WhiteboardStore.replaceForSync 逐键写入。
    static func apply(
        base boards: [String: WhiteboardSpec],
        base times: [String: Date],
        remote: [SyncWireItem<Payload>],
        tombstones: [String: Date]
    ) -> (boards: [String: WhiteboardSpec], times: [String: Date]) {
        var boards = boards
        var times = times

        // 远端墓碑：本端有同键板且板比墓碑旧（或无戳）才删；本端更新过 = 本端赢，
        // 保留（collect 会以新戳重推，服务端复活）。
        for (conversationId, deletedAt) in tombstones {
            if let localAt = times[conversationId], localAt > deletedAt { continue }
            boards[conversationId] = nil
            times[conversationId] = nil
        }

        // 远端文档：旧 → 忽略；同刻（含同一台设备重推）→ 忽略；新 → 盖写。
        let sorted = remote.sorted { $0.clientUpdatedAt < $1.clientUpdatedAt }
        for item in sorted {
            guard item.deleted != true, let payload = item.payload else { continue }
            let id = payload.conversationId
            let remoteAt = item.clientUpdatedAt
            if let localAt = times[id], localAt >= remoteAt { continue }
            var incoming = payload
            let localBlocks = boards[id]?.blocks ?? []
            // 图像回填：占位符块按 UUID 从本地板找回原图。
            for i in incoming.blocks.indices
            where incoming.blocks[i].content == Self.imagePlaceholder {
                if let local = localBlocks.first(where: { $0.id == incoming.blocks[i].id }),
                   local.type == WhiteboardBlock.Kind.image {
                    incoming.blocks[i].content = local.content
                }
            }
            boards[id] = WhiteboardSpec(title: incoming.title, blocks: incoming.blocks)
            times[id] = remoteAt
        }
        times = times.filter { boards[$0.key] != nil }
        return (boards, times)
    }

    /// 编码后的字符数（体量护栏用；Foundation-only）。
    private static func JSONEncodeCount(_ payload: Payload) -> Int {
        guard let data = try? JSONEncoder().encode(payload) else { return .max }
        return data.count
    }
}
