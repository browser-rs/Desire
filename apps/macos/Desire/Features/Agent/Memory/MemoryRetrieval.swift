import Foundation

/// BM25 记忆检索（2026-10-02 个性化增强 6）：L1 事实 200 条上限下，
/// 按与**当前对话**的词法相关性挑最值得注入的少数条目——全量注入既爆
/// 上下文又稀释注意力（无关记忆比没有更糟）。
///
/// Foundation-only（进 tests/run.sh）。打分 = Okapi BM25，分词：
/// 英文按 [a-z0-9]+ 词元、中文按**字符 bigram**（与 MemoryModels 的
/// 去重同款近似——无端上 embedding 时的下限方案）。
enum MemoryRetrieval {
    struct Params {
        /// 注入上限（pinned 之外的 BM25 名额）。
        var topK: Int = 12
        /// BM25 参数：k1 词频饱和、b 长度归一。
        var k1: Double = 1.2
        var b: Double = 0.75
    }

    /// 查询文本分词：英文词元 + 中文 bigram。
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        var cjkRun: [Character] = []
        func flushLatin() {
            if !latin.isEmpty { tokens.append(latin); latin = "" }
        }
        func flushCJK() {
            // 中文连续段切 bigram（单字保留——单字查询词也要能命中）。
            guard cjkRun.count > 1 else {
                if let only = cjkRun.first { tokens.append(String(only)) }
                cjkRun = []
                return
            }
            for i in 0...(cjkRun.count - 2) {
                tokens.append(String(cjkRun[i]) + String(cjkRun[i + 1]))
            }
            cjkRun = []
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                if ch.unicodeScalars.allSatisfy({ $0.properties.isIdeographic
                    || ($0.value >= 0x3040 && $0.value <= 0x30FF) }) {
                    flushLatin()
                    cjkRun.append(ch)
                } else {
                    flushCJK()
                    latin.append(ch)
                }
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return tokens
    }

    struct Scored {
        let fact: MemoryFact
        let score: Double
    }

    /// BM25 排序。返回 (pinned 恒定在前) + 非 pinned 按 BM25 分数取 topK；
    /// **全部 0 分**（词法无重叠）时退化为最近优先取 topK 条（新记忆先验
    /// 更相关）——绝不注入 0 分且陈旧的沉底项。
    static func rank(facts: [MemoryFact], query: String, params: Params = Params()) -> [MemoryFact] {
        let pinned = facts.filter { $0.pinned }
        let pool = facts.filter { !$0.pinned }
        guard !pool.isEmpty else { return pinned }

        let queryTokens = tokenize(query)
        // 无可用查询词（冷启动首条消息前）→ 最近优先。
        guard !queryTokens.isEmpty else {
            let recent = pool.sorted { $0.updatedAt > $1.updatedAt }.prefix(params.topK)
            return pinned + recent
        }

        // 文档词频 + 平均长度（文档 = content + category，category 词也算命中）。
        var docTokens: [[String]] = []
        var totalLength = 0.0
        for fact in pool {
            let tokens = tokenize(fact.content + " " + fact.category)
            docTokens.append(tokens)
            totalLength += Double(tokens.count)
        }
        let avgLength = totalLength / Double(pool.count)
        guard avgLength > 0 else { return pinned + pool.prefix(params.topK) }

        var df: [String: Int] = [:]
        for tokens in docTokens {
            for token in Set(tokens) {
                df[token, default: 0] += 1
            }
        }
        let n = Double(pool.count)
        func idf(_ term: String) -> Double {
            let seen = Double(df[term] ?? 0)
            // BM25+ 风格平滑：未见词不为负。
            return log((n - seen + 0.5) / (seen + 0.5) + 1.0)
        }

        var scored: [Scored] = []
        for (index, fact) in pool.enumerated() {
            let tokens = docTokens[index]
            var tf: [String: Int] = [:]
            for t in tokens { tf[t, default: 0] += 1 }
            var score = 0.0
            for term in Set(queryTokens) {
                let freq = Double(tf[term] ?? 0)
                guard freq > 0 else { continue }
                let lengthNorm = Double(tokens.count) / avgLength
                score += idf(term) * (freq * (params.k1 + 1))
                    / (freq + params.k1 * (1 - params.b + params.b * lengthNorm))
            }
            // 来源会话标题也算轻量命中面（同一会话学到的记忆更可能相关）。
            if let source = fact.source, !source.isEmpty,
               Set(tokenize(source)).contains(where: { Set(queryTokens).contains($0) }) {
                score += 0.5
            }
            scored.append(Scored(fact: fact, score: score))
        }

        let hits = scored
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(params.topK)
        let selected = hits.map(\.fact)
        if selected.isEmpty {
            // 词法零重叠：最近优先兜底（不注入沉底的陈旧项）。
            let recent = pool.sorted { $0.updatedAt > $1.updatedAt }.prefix(params.topK)
            return pinned + recent
        }
        return pinned + selected
    }
}
