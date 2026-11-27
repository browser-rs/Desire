import Foundation

/// 自评之后"要不要自动修订"的判定（v0.8.80 批 3）：只有**客观失败证据** +
/// 评语明确指了问题才修订一次；评语说"未发现问题"或没有任何机械证据时不打扰。
///
/// 纯逻辑（Foundation-only），供 harness 单测与回合收尾共用。
nonisolated enum AnswerRevision {
    /// 最长输入预算（字符）：超出就放弃自动修订——一次修订的上下文不无限膨胀。
    static let maxContextChars = 60_000
    /// 修订稿最多允许比原答案长这么多倍（防止模型借"修订"重写整篇跑题）。
    static let maxGrowthFactor = 2.0

    /// 评语是否明确表示"没有问题"。模型有中英两种常见说法；用归一化后的
    /// 子串命中（保守：命中即视为无需修订）。
    static func saysNoIssues(_ critique: String) -> Bool {
        let text = critique
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !text.isEmpty else { return true }
        let markers = [
            "未发现问题", "没有问题", "无需修订", "无需修改", "没有发现",
            "no issues found", "no problems found", "no issues", "nothing to fix",
            "looks good", "no changes needed",
        ]
        return markers.contains { text.contains($0) }
    }

    /// `verificationNote` = 机械核验的客观结论；`failedCalls` = 本轮被拒/报错的
    /// 工具调用数。二者至少有一个才算"有客观失败证据"。
    static func shouldRevise(critique: String, verificationNote: String?,
                             failedCalls: Int, answer: String) -> Bool {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return false }
        guard !saysNoIssues(critique) else { return false }
        let hasEvidence = failedCalls > 0
            || !(verificationNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasEvidence
    }

    /// 修订稿验收：非空、没有失控地变长。
    static func accepts(revised: String, original: String) -> Bool {
        let trimmed = revised.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let limit = max(Int(Double(original.count) * maxGrowthFactor), 2_000)
        return trimmed.count <= limit
    }
}
