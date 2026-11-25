import Foundation

/// **技能使用记录**（v0.8.72 批 3；v0.8.76 从 `SkillStore` 里抽成独立文件——编解码
/// 要进纯逻辑 harness，嵌在 Store 里的类型测不到，下面那个 bug 就是这样漏过去的）。
///
/// 口径 = useSkill 调用（注入 ≠ 使用）；回合结果由会话收尾批量回填
/// （`SkillStore.recordOutcome`）——技能成功率的数据面。
nonisolated struct SkillUsageRecord: Codable, Equatable, Sendable {
    var count: Int = 0
    var lastUsedAt: Date?
    /// 最近一次使用的会话（v0.8.73 批 3）：连败技能"重新蒸馏"定位该
    /// 会话的运行记录；会话可能已清理（按钮据此置灰）。
    var lastUsedConversationId: UUID?
    /// 触发样本（v0.8.76 批 3）：加载这个技能时用户说的话与次数（最近的在前）。
    /// 可选——旧记录没有这个键。
    var triggers: [SkillTrigger.Sample]?
    /// 加载这个技能的回合里实际调用过的工具 → 次数（v0.8.76 批 5，按任务精简
    /// 工具定义的推断来源之一）。可选——旧记录没有这个键。
    var toolNames: [String: Int]?
    /// 最近 ≤20 个回合的成功/失败（时间序）。空 = 无样本（"样本不足"）。
    var outcomes: [Bool] = []
    /// 成功率（无样本返回 nil——UI 标"样本不足"，绝不显示 0%）。
    var successRate: Double? {
        guard !outcomes.isEmpty else { return nil }
        return Double(outcomes.filter { $0 }.count) / Double(outcomes.count)
    }
}

/// 使用记录的编解码——**读写必须成对**。
///
/// 事故（2026-11-25，批 5 实测重启后才发现）：写入端一直用 `SyncJSON.makeEncoder()`
/// （日期编码成 `"2026-11-25T06:22:37.540859"` 这样的字符串），读取端却是裸
/// `JSONDecoder()`（日期要数字）。只要一条记录带 `lastUsedAt`，整个字典解码失败，
/// 启动时**静默清空**——从 0.8.72 起每次启动都如此：成功率归零、学到的触发样本
/// 丢失，而回填标记是一次性的、不会再补。此前所有测试都没跨启动断言过这份记录。
///
/// 现有用户盘上的数据本来就是这个字符串格式，换成成对的解码器即可读回，无需迁移。
nonisolated enum SkillUsageCodec {

    /// 写入（与盘上已有格式一致）。失败返回 nil——调用方不覆盖旧值。
    static func encode(_ usage: [String: SkillUsageRecord]) -> Data? {
        try? SyncJSON.makeEncoder().encode(usage)
    }

    /// 读回。返回 nil = 数据读不出来（调用方保持空，不写回，避免把读不出的旧值盖掉）。
    static func decode(_ data: Data) -> [String: SkillUsageRecord]? {
        try? SyncJSON.makeDecoder().decode([String: SkillUsageRecord].self, from: data)
    }
}
