import Foundation

/// 运营数据同步（v0.9.0 第十一类域）。
///
/// 七类数据（目标/帖子/账号/实验/互动/战役/竞品来源）走一个 `promotion` 域，
/// 每条记录的 client_id = 记录 UUID 的 HMAC（与 agent_memory 同款）；
/// payload = 密文 JSON（AES-256-GCM，主密钥 HKDF 派生）；LWW 冲突仲裁；
/// 删除走 tombstone（PromotionStore.pendingDeletions）。
///
/// 适配包/归因事件不同步（设备本地 / 服务器聚合）。
nonisolated enum SyncPromotion {

    // MARK: - 同步载荷模型

    /// 七选一枚举（与 agent_memory 同款模式）。
    enum SyncKind: String, Codable {
        case goal
        case post
        case account
        case experiment
        case interaction
        case campaign
        case competitor
    }

    /// 客户端统一载荷：kind + 实体 JSON（由 Codable 自动编解码）。
    enum SyncPayload: Codable {
        case goal(PromotionGoal)
        case post(PromotionPost)
        case account(PromotionAccount)
        case experiment(PromotionExperiment)
        case interaction(PromotionInteraction)
        case campaign(PromotionCampaign)
        case competitor(PromotionCompetitorSource)

        private enum CodingKeys: String, CodingKey {
            case kind, data
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(SyncKind.self, forKey: .kind)
            switch kind {
            case .goal: self = .goal(try c.decode(PromotionGoal.self, forKey: .data))
            case .post: self = .post(try c.decode(PromotionPost.self, forKey: .data))
            case .account: self = .account(try c.decode(PromotionAccount.self, forKey: .data))
            case .experiment: self = .experiment(try c.decode(PromotionExperiment.self, forKey: .data))
            case .interaction: self = .interaction(try c.decode(PromotionInteraction.self, forKey: .data))
            case .campaign: self = .campaign(try c.decode(PromotionCampaign.self, forKey: .data))
            case .competitor: self = .competitor(try c.decode(PromotionCompetitorSource.self, forKey: .data))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .goal(let v):
                try c.encode(SyncKind.goal, forKey: .kind)
                try c.encode(v, forKey: .data)
            case .post(let v):
                try c.encode(SyncKind.post, forKey: .kind)
                try c.encode(v, forKey: .data)
            case .account(let v):
                try c.encode(SyncKind.account, forKey: .kind)
                try c.encode(v, forKey: .data)
            case .experiment(let v):
                try c.encode(SyncKind.experiment, forKey: .kind)
                try c.encode(v, forKey: .data)
            case .interaction(let v):
                try c.encode(SyncKind.interaction, forKey: .kind)
                try c.encode(v, forKey: .data)
            case .campaign(let v):
                try c.encode(SyncKind.campaign, forKey: .kind)
                try c.encode(v, forKey: .data)
            case .competitor(let v):
                try c.encode(SyncKind.competitor, forKey: .kind)
                try c.encode(v, forKey: .data)
            }
        }
    }

    // MARK: - 纯逻辑：LWW 合并（进 harness）

    struct MergeResult: Equatable {
        /// 远端比本机新 → 用远端的。
        var appliedRemote: [String]
        /// 本机比远端新 → 保留本机（并重新盖戳推上去）。
        var keptLocal: [String]
        /// 远端 tombstone 命中本机条目 → 删除。
        var deleted: [String]
        /// 完全新的远端条目 → 新增。
        var added: [String]
    }

    /// 通用 LWW 合并：比较 clientUpdatedAt，远端新则覆盖。
    /// 参数为 (localID, localUpdatedAt) 列表 + (remoteID, remoteUpdatedAt, deleted) 列表。
    static func merge(
        local: [(id: String, updatedAt: Date)],
        remote: [(id: String, updatedAt: Date, deleted: Bool)]
    ) -> MergeResult {
        var result = MergeResult(appliedRemote: [], keptLocal: [], deleted: [], added: [])
        let localMap = Dictionary(uniqueKeysWithValues: local)
        for r in remote {
            if r.deleted {
                if localMap[r.id] != nil {
                    result.deleted.append(r.id)
                }
                continue
            }
            if let l = localMap[r.id] {
                if r.updatedAt > l {
                    result.appliedRemote.append(r.id)
                } else {
                    result.keptLocal.append(r.id)
                }
            } else {
                result.added.append(r.id)
            }
        }
        return result
    }

    // MARK: - HMAC client_id

    nonisolated static func clientID(for entityID: String, masterKeyBase64: String) -> String {
        (try? SyncCrypto.hmacClientID(
            entityID, domain: .promotion, masterKeyBase64: masterKeyBase64)) ?? ""
    }
}
