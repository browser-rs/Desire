import Foundation

/// **技能自动候选**的纯逻辑半边（v0.8.72 批 2，Foundation-only 进 tests/run.sh）：
/// 把"这次任务值得沉淀成技能吗"的判定、旁路蒸馏的节流、候选的过期清洗
/// 收口成可测函数；Store 只做薄壳（持久化 + UI）。
///
/// 原则（沿用 SkillDistiller 的"不静默存烂技能"）：候选**永不自动进入**
/// 正式技能库——只浮出来等用户采纳；失败/取消回合绝不触发；节流防旁路烧钱。
nonisolated enum SkillCandidateCore {

    /// 候选技能草稿（蒸馏产物 + 来源）。
    struct Candidate: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var description: String
        var instructions: String
        var createdAt: Date
        var conversationId: UUID?

        init(name: String, description: String, instructions: String,
             conversationId: UUID?, now: Date = Date()) {
            self.id = UUID()
            self.name = name
            self.description = description
            self.instructions = instructions
            self.createdAt = now
            self.conversationId = conversationId
        }
    }

    /// **资格判定**：回合干净成功 + 工具步骤链够长（≥6 次工具调用——
    /// 一两步的问答没有可复用的流程）。失败/取消回合在调用侧已被
    /// lastTurnSucceeded 挡住，这里再兜一道。
    static func qualifies(turnToolCount: Int, turnSucceeded: Bool) -> Bool {
        turnSucceeded && turnToolCount >= 6
    }

    /// **节流**（防旁路蒸馏烧钱）：全局 24h 滚动 ≤ `maxPerDay`；同一会话
    /// 最多 `perConversation` 次（默认 1——提炼过一次就不再打扰）。
    static func throttlePasses(offeredAt: [Date], conversationIDs: [UUID],
                               conversationId: UUID?, now: Date,
                               maxPerDay: Int = 6,
                               perConversation: Int = 1,
                               cooldown: TimeInterval = 24 * 3_600) -> Bool {
        let windowStart = now.addingTimeInterval(-cooldown)
        let recent = offeredAt.filter { $0 >= windowStart }
        guard recent.count < maxPerDay else { return false }
        if let conversationId {
            let forThis = conversationIDs.filter { $0 == conversationId }.count
            guard forThis < perConversation else { return false }
        }
        return true
    }

    /// **过期清洗**：候选 7 天没人理就算了（收件箱不是垃圾桶）。
    static func expiring(_ candidates: [Candidate], now: Date,
                         ttl: TimeInterval = 7 * 86_400) -> [Candidate] {
        candidates.filter { now.timeIntervalSince($0.createdAt) < ttl }
    }

    /// **采纳前查重**：同名正式技能已存在 → 候选没有存在意义（同名覆盖
    /// 是用户显式编辑的语义，不是候选的）。
    static func isRedundant(name: String, existingSkillNames: [String],
                            pendingCandidates: [Candidate]) -> Bool {
        let lowered = name.lowercased()
        if existingSkillNames.contains(where: { $0.lowercased() == lowered }) { return true }
        return pendingCandidates.contains { $0.name.lowercased() == lowered }
    }
}

/// **技能健康评估**（v0.8.72 批 3，B3）：把使用统计（SkillStore.usage）翻译
/// 成展示语义——只提示不硬闸；样本 <5 如实标注"样本不足"，绝不显示 0%。
/// 判定顺序：未使用 → 连败预警（≥3 连败即提示，早于样本阈值——连败是
/// 最有用的信号）→ 样本不足 → 健康。
nonisolated enum SkillHealth {

    enum Status: Equatable {
        case unused
        case insufficientSamples
        case healthy(rate: Double)
        case failingStreak(count: Int)
    }

    static func assess(count: Int, outcomes: [Bool], minSamples: Int = 5,
                       failingStreakThreshold: Int = 3) -> Status {
        guard count > 0 else { return .unused }
        var streak = 0
        for outcome in outcomes.reversed() where !outcome { streak += 1 }
        if streak > 0, outcomes.count >= streak, streak >= failingStreakThreshold {
            return .failingStreak(count: streak)
        }
        guard outcomes.count >= minSamples else { return .insufficientSamples }
        let rate = Double(outcomes.filter { $0 }.count) / Double(outcomes.count)
        return .healthy(rate: rate)
    }
}
