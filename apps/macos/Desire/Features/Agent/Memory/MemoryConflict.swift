import Foundation

/// 「记忆冲突复核」的**纯逻辑**（v0.7.22；Foundation-only 进 harness）。
///
/// 口径先说清楚：没有端到端语义理解，这里做的是**近似判定**——把与新增
/// 文本"相关"的既有事实挑出来给用户复核，**不声称检测到了语义冲突**。
/// 面板文案与桥回执都照这个口径写（"可能相关/建议复核"）。
nonisolated enum MemoryConflict {

    enum Kind: String, Codable, Equatable {
        /// 近似重复（归一化 + bigram ≥ 0.8，与入库去重同一判据）。
        case nearDuplicate
        /// 同桶（类别或作用域相同）且显著词重叠 ≥ 阈值——"同一主题的另一种说法"。
        case related
    }

    struct Candidate: Equatable {
        let factID: UUID
        let kind: Kind
        let overlap: Double
    }

    /// 与 `text` 相关的既有事实（按重叠度降序）。
    /// 桶判定：类别或作用域相同才提示（完全无关的桶不打扰）；重叠度用
    /// **containment**（交集 / 较短边）——新增常常是旧记忆的细化/改写，
    /// 对称 Jaccard 会把"短句 vs 长句"压得过低。
    static func candidates(for text: String, category: String, scope: String,
                           facts: [MemoryFact],
                           threshold: Double = 0.34) -> [Candidate] {
        let normalized = MemoryModels.normalizeFact(text)
        let tokens = Set(MemoryRetrieval.tokenize(text))
        guard !tokens.isEmpty else { return [] }
        var out: [Candidate] = []
        for fact in facts {
            guard fact.category == category || fact.scope == scope else { continue }
            let other = Set(MemoryRetrieval.tokenize(fact.content))
            guard !other.isEmpty else { continue }
            let overlap = Double(tokens.intersection(other).count) / Double(min(tokens.count, other.count))
            if MemoryModels.areNearDuplicates(MemoryModels.normalizeFact(fact.content), normalized) {
                out.append(Candidate(factID: fact.id, kind: .nearDuplicate, overlap: overlap))
            } else if overlap >= threshold {
                out.append(Candidate(factID: fact.id, kind: .related, overlap: overlap))
            }
        }
        return out.sorted { a, b in
            if a.kind != b.kind { return a.kind == .nearDuplicate }
            return a.overlap > b.overlap
        }
    }

    /// 合并文案的兜底拼接（用户没手编 merge 文本时用）：新句在前，旧句以
    /// "；"衔接、去重完全相同的片段。
    static func defaultMergedText(new: String, related: [String]) -> String {
        var parts: [String] = []
        let trimmedNew = new.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in [trimmedNew] + related.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !candidate.isEmpty, !parts.contains(candidate) else { continue }
            parts.append(candidate)
        }
        return parts.joined(separator: "；")
    }
}
