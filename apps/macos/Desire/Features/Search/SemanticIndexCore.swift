import Foundation

/// 端上语义索引的**纯逻辑**（v0.8.22）：条目身份/语言路由/内容哈希/
/// 向量近邻/增量 diff。Foundation-only，进 tests/run.sh。
///
/// 三条口径（改之前先读）：
/// - 索引按 **来源 × 语言** 分片：中文走 bge-small-zh、英文走系统
///   NLEmbedding 句向量，两套模型维度与语义空间都不同，**跨分片余弦没有
///   意义**——所以查询只与同语言分片比较，绝不混算。
/// - 条目 id 是稳定字符串（来源前缀 + 原 url/uuid），增量以 `contentHash`
///   判断能否复用旧向量；条目没了就丢向量，不保留孤儿。
/// - 排序确定性：分数相同按 id 升序，保证同输入同输出（harness 与 E2E 都
///   依赖这一点）。

// MARK: - 来源

nonisolated enum SemanticSource: String, Codable, CaseIterable, Sendable {
    case history
    case bookmark
    case excerpt
    case highlight
    case conversation

    /// 设置页/桥端点里的稳定键（本地化在视图层做）。
    var stableKey: String { rawValue }
}

// MARK: - 语言

nonisolated enum SemanticLanguage: String, Codable, CaseIterable, Sendable {
    case chinese
    case latin

    /// 写进分片 manifest 的模型标识——模型换了旧向量必须重嵌。
    var modelKey: String {
        switch self {
        case .chinese: return "bge-small-zh-v1.5"
        case .latin: return "apple-nl-sentence-en"
        }
    }
}

// MARK: - 文本处理

nonisolated enum SemanticText {
    /// 折叠所有空白（含换行）为单空格并去首尾。
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// 按字符（grapheme）截断——不会切坏多字节字符。
    static func clip(_ text: String, max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max))
    }

    /// CJK 统一表意文字计数（语言路由与"语义信息量"判定共用）。
    static func cjkCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                count += 1
            }
        }
        return count
    }

    /// 语言路由：CJK 字符达到 2 个且占 ASCII 字母的 1/4 以上 → 中文。
    /// 纯数字/符号按 latin 处理（回退路径可用）。
    static func detectLanguage(_ text: String) -> SemanticLanguage {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                cjk += 1
            } else if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
                latin += 1
            }
        }
        return (cjk >= 2 && cjk * 4 >= latin) ? .chinese : .latin
    }

    /// 送去嵌入的正文：标题 + 正文，封顶 `maxChars`（bge 只吃 512 token，
    /// 多出来的部分不增加信息量，只会拖慢构建）。
    static func embedInput(title: String, body: String, maxChars: Int = 1_200) -> String {
        let head = collapseWhitespace(title)
        let tail = collapseWhitespace(body)
        if tail.isEmpty { return clip(head, max: maxChars) }
        if head.isEmpty { return clip(tail, max: maxChars) }
        return clip(head + "\n" + tail, max: maxChars)
    }

    /// 内容哈希（FNV-1a 64 位，十六进制）。确定性、不依赖哈希种子——
    /// **不能**用 `String.hashValue`：它每次进程启动都不同，跨启动的增量
    /// 复用会全部失效。
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    static func contentHash(title: String, body: String) -> String {
        fnv1a(title + "\u{1f}" + body)
    }

    /// 检索结果的一行摘要（批一先做前缀截断；定位高亮在检索 UI 批做）。
    static func snippet(_ body: String, max: Int = 180) -> String {
        clip(collapseWhitespace(body), max: max)
    }
}

// MARK: - 条目与向量

nonisolated struct SemanticItem: Codable, Equatable, Sendable {
    /// 稳定身份："<source>:<url 或 uuid>"。
    var id: String
    var source: SemanticSource
    var title: String
    var subtitle: String
    var body: String
    var updatedAt: Date
    var language: SemanticLanguage
    var contentHash: String

    init(source: SemanticSource, externalID: String, title: String,
         subtitle: String, body: String, updatedAt: Date) {
        self.id = "\(source.rawValue):\(externalID)"
        self.source = source
        self.title = SemanticText.collapseWhitespace(title)
        self.subtitle = SemanticText.collapseWhitespace(subtitle)
        self.body = SemanticText.clip(SemanticText.collapseWhitespace(body), max: 1_200)
        self.updatedAt = updatedAt
        let probe = SemanticText.embedInput(title: self.title, body: self.body)
        self.language = SemanticText.detectLanguage(probe)
        self.contentHash = SemanticText.contentHash(title: self.title, body: self.body)
    }
}

nonisolated struct SemanticVectorRecord: Codable, Equatable, Sendable {
    var id: String
    var contentHash: String
    var vector: [Float]
}

// MARK: - 近邻

nonisolated enum SemanticRanking {
    struct Hit: Equatable, Sendable {
        var record: SemanticVectorRecord
        var score: Float
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// 分数降序、同分按 id 升序（确定性）；低于 `minScore` 的不出。
    static func topK(query: [Float], records: [SemanticVectorRecord],
                     limit: Int, minScore: Float) -> [Hit] {
        guard limit > 0, !records.isEmpty else { return [] }
        var hits: [Hit] = []
        hits.reserveCapacity(records.count)
        for record in records {
            let score = cosine(query, record.vector)
            if score >= minScore {
                hits.append(Hit(record: record, score: score))
            }
        }
        hits.sort {
            if $0.score == $1.score { return $0.record.id < $1.record.id }
            return $0.score > $1.score
        }
        return Array(hits.prefix(limit))
    }
}

// MARK: - 增量

nonisolated enum SemanticIncremental {
    struct Plan: Equatable, Sendable {
        /// 未变条目：id → 旧向量（直接复用，不重嵌）。
        var reuse: [String: [Float]]
        /// 新条目或内容变了的条目（需要重新嵌入）。
        var pending: [SemanticItem]
    }

    /// 只有 id 相同**且** contentHash 相同才复用向量；内容变了必须重嵌，
    /// 否则改了备注/正文的条目永远搜不到新内容。
    static func plan(previous: [SemanticVectorRecord], items: [SemanticItem]) -> Plan {
        var byID: [String: SemanticVectorRecord] = [:]
        byID.reserveCapacity(previous.count)
        for record in previous { byID[record.id] = record }

        var reuse: [String: [Float]] = [:]
        var pending: [SemanticItem] = []
        for item in items {
            if let old = byID[item.id], old.contentHash == item.contentHash, !old.vector.isEmpty {
                reuse[item.id] = old.vector
            } else {
                pending.append(item)
            }
        }
        return Plan(reuse: reuse, pending: pending)
    }
}

// MARK: - 查询门槛

nonisolated enum SemanticQueryPlan {
    /// 太短的查询（单字符）语义化没有意义，交给字面检索。
    static func isSemanticWorthy(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return trimmed.contains { $0.isLetter || $0.isNumber }
    }

    /// 查询语言：与条目侧同一套判定，用于选定主分片。
    static func primaryLanguage(for query: String) -> SemanticLanguage {
        SemanticText.detectLanguage(query)
    }
}

// MARK: - 分片 manifest / 指纹

nonisolated struct SemanticShardManifest: Codable, Equatable, Sendable {
    var version: Int
    var source: SemanticSource
    var language: SemanticLanguage
    var model: String
    var dimension: Int
    var itemCount: Int
    var builtAt: Date
    /// 条目集合指纹（与顺序无关）——用于判断要不要重建。
    var fingerprint: String

    static let currentVersion = 1
}

nonisolated enum SemanticFingerprint {
    /// 与顺序无关：排序后拼接再哈希。
    static func of(_ items: [SemanticItem]) -> String {
        let hashes = items.map { $0.contentHash }.sorted()
        return SemanticText.fnv1a(hashes.joined(separator: ","))
    }
}

// MARK: - 状态汇总（设置页/桥端点共用）

nonisolated struct SemanticSourceStatus: Equatable, Sendable {
    var source: SemanticSource
    var language: SemanticLanguage
    var itemCount: Int
    var vectorCount: Int
    var bytes: Int
    var builtAt: Date?
    var model: String
}

nonisolated enum SemanticStatusMath {
    /// 各分片按来源聚合（同来源两种语言合成一条）。
    static func aggregate(_ shards: [SemanticSourceStatus]) -> [SemanticSourceStatus] {
        var order: [SemanticSource] = []
        var merged: [SemanticSource: SemanticSourceStatus] = [:]
        for shard in shards {
            if var existing = merged[shard.source] {
                existing.itemCount += shard.itemCount
                existing.vectorCount += shard.vectorCount
                existing.bytes += shard.bytes
                if let built = shard.builtAt {
                    existing.builtAt = max(existing.builtAt ?? built, built)
                }
                if existing.model.split(separator: "+").count < 2,
                   !existing.model.contains(shard.model) {
                    existing.model += "+" + shard.model
                }
                merged[shard.source] = existing
            } else {
                order.append(shard.source)
                merged[shard.source] = shard
            }
        }
        return order.compactMap { merged[$0] }
    }
}
