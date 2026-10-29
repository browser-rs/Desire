import Foundation

/// 向量聚类的**纯逻辑**（v0.8.22）：知识周报与收件箱主题分组共用。
///
/// 贪心、确定性（同输入同输出）：
/// - 按传入顺序遍历，与已有簇**质心**的余弦 ≥ threshold 就并入最相似的簇；
///   否则新建簇；簇数到上限后并入最相似簇（不再新建）。
/// - 跨语言向量不可比——调用方按语言分组后再分别调用（见 KnowledgeWeeklyDigest）。
/// - 输出按簇大小降序，同大小按首个 id 升序。
///
/// Foundation-only，进 tests/run.sh。
nonisolated enum SemanticClusterCore {
    struct VectorItem: Equatable, Sendable {
        var id: String
        var vector: [Float]
    }

    static func cluster(_ items: [VectorItem],
                        threshold: Float = 0.62,
                        maxClusters: Int = 8) -> [[String]] {
        guard !items.isEmpty else { return [] }
        var clusters: [(ids: [String], sum: [Float], count: Int)] = []

        for item in items {
            guard !item.vector.isEmpty else { continue }
            var bestIndex: Int?
            var bestScore: Float = -1
            for (index, cluster) in clusters.enumerated() {
                guard cluster.count > 0, cluster.sum.count == item.vector.count else { continue }
                let centroid = normalizedCentroid(cluster.sum, cluster.count)
                let score = cosine(item.vector, centroid)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            if let index = bestIndex, bestScore >= threshold {
                absorb(index, item, into: &clusters)
            } else if clusters.count < max(1, maxClusters) {
                clusters.append(([item.id], item.vector, 1))
            } else if let index = bestIndex {
                absorb(index, item, into: &clusters)
            } else {
                clusters.append(([item.id], item.vector, 1))
            }
        }

        return clusters
            .map { $0.ids }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return (lhs.first ?? "") < (rhs.first ?? "")
            }
    }

    /// 质心（运行均值再归一化）——聚类过程中用它，避免被后加入的长向量主导。
    static func normalizedCentroid(_ sum: [Float], _ count: Int) -> [Float] {
        guard count > 0, !sum.isEmpty else { return [] }
        var mean = sum.map { $0 / Float(count) }
        let norm = mean.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return mean }
        mean = mean.map { $0 / norm }
        return mean
    }

    private static func absorb(_ index: Int, _ item: VectorItem,
                               into clusters: inout [(ids: [String], sum: [Float], count: Int)]) {
        clusters[index].ids.append(item.id)
        if clusters[index].sum.count == item.vector.count {
            for position in 0..<item.vector.count {
                clusters[index].sum[position] += item.vector[position]
            }
        }
        clusters[index].count += 1
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return -1 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in 0..<a.count {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return -1 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
