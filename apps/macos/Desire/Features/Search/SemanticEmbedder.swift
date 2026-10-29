import Foundation
import NaturalLanguage

/// 端上向量化的**单点收口**（v0.8.22）：中文走 bge-small-zh-v1.5（与记忆
/// 检索同一个 22MB 模型），英文走系统 `NLEmbedding` 句向量。
///
/// 为什么分两套：bge-small-zh 是中文模型，英文质量无保障；系统的
/// `NLEmbedding.sentenceEmbedding(for: .english)` 在英文上够用且零额外体积。
/// 两套向量的**维度与语义空间都不同**——分片存储、查询只与同语言分片比较。
///
/// 质量依据（tools/vector-spike/semantic-en-spike.swift，24 篇构造语料 /
/// 23 条查询）：英文侧 NL 句向量 recall@5 0.913、同义改写查询 recall@1
/// 12/18，字面词重叠基线只有 0.478 / 6/18；但主题词查询字面更强
/// （4/5 vs 3/5）——所以检索侧是"字面优先、语义补位"，语义不做唯一排序。
/// 中文侧沿用 0.7.1 的 bge 验收集（13/15 vs BM25 8/15）。
nonisolated enum SemanticEmbedder {
    /// 检索侧最低分（按语言分别标定）：
    /// - 英文：gold 平均 0.407、非 gold 平均 0.153（max 0.448）——取 0.30，
    ///   保住 20/23 的 gold，同时把大部分无关条目挡在外面（top-k 再收一道）。
    /// - 中文：bge 实测（书签语料 + 官方查询前缀）——同义改写命中 0.431、
    ///   无关查询 0.364、字面同题 0.72。取 0.40：保住改写命中，挡住无关项。
    ///   查询侧必须带 bge 官方指令前缀（见 embedQuery）。
    /// - 英文：门槛从 spike 的 0.30 提到 0.38——书签这类**短标题**实测
    ///   无关条目也能到 0.40+（"P2-RERUN-REMOTE" 0.429），0.30 会把噪声
    ///   放进结果；0.38 仍能保住同义改写类命中（gold 0.45+）。
    static func minScore(for language: SemanticLanguage) -> Float {
        switch language {
        case .chinese: return 0.40
        case .latin: return 0.38
        }
    }

    struct Output: Sendable {
        var vector: [Float]
        var model: String
        var dimension: Int { vector.count }
    }

    /// **查询侧**嵌入：中文必须走 bge 的官方查询指令前缀（`embedQuery`），
    /// 与事实侧（`embed`，不加前缀）配对才有 0.7.1 验收集的召回水平；
    /// 英文句向量没有这个区分。
    static func embedQuery(_ text: String, language: SemanticLanguage) -> Output? {
        guard language == .chinese else { return embed(text, language: language) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let raw = BGEEmbedder.embedQuery(trimmed) else { return nil }
        guard let vector = normalize(raw.map { Float($0) }) else { return nil }
        return Output(vector: vector, model: language.modelKey)
    }

    /// **条目侧**嵌入：失败一律返回 nil（模型缺失/文本为空/非有限值/零向量）
    /// ——调用方跳过该条目并计数，绝不写入坏向量。
    static func embed(_ text: String, language: SemanticLanguage) -> Output? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch language {
        case .chinese:
            guard let raw = BGEEmbedder.embed(trimmed) else { return nil }
            guard let vector = normalize(raw.map { Float($0) }) else { return nil }
            return Output(vector: vector, model: language.modelKey)
        case .latin:
            guard let embedding = englishEmbedding,
                  let raw = embedding.vector(for: trimmed) else { return nil }
            guard let vector = normalize(raw.map { Float($0) }) else { return nil }
            return Output(vector: vector, model: language.modelKey)
        }
    }

    /// NLEmbedding 构造有系统模型开销，别每条目建一次。构建是串行后台任务，
    /// 且 `vector(for:)` 是只读调用——`nonisolated(unsafe)` 在此成立。
    nonisolated(unsafe) private static let englishEmbedding: NLEmbedding? =
        NLEmbedding.sentenceEmbedding(for: .english)

    /// L2 归一化；顺带拒绝 NaN/Inf（它们会污染余弦与排序）。
    private static func normalize(_ raw: [Float]) -> [Float]? {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isFinite }) else { return nil }
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return raw.map { $0 / norm }
    }
}
