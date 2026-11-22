import Foundation

/// **记忆体检**的纯逻辑半边（v0.8.73 批 2，Foundation-only 进 tests/run.sh）：
/// 手动触发的 consolidation pass——近重复合并（0.9 严阈值）、陈旧退役
/// （>60 天未用移出注入池）、报告统计。Store 侧负责落盘/墓碑/导出/冲突清账。
///
/// 三条纪律：合并只动 unpinned；被合并/退役的原文**先导出归档**（不丢原文，
/// 退役 ≠ 删除）；冲突（pendingConflicts）只计数不清账——清账走既有的
/// keepNew/keepOld 复核语义。
nonisolated enum MemoryCheckupCore {

    struct Report: Equatable {
        let totalBefore: Int
        let mergedClusters: Int
        let mergedRemoved: Int
        let retired: Int
        let pendingConflicts: Int
        var totalAfter: Int { totalBefore - mergedRemoved - retired }
    }

    /// 合并阈值：比注入去重（0.8）严——体检动的是落盘事实，宁可漏合不误合。
    static let mergeThreshold: Double = 0.9
    static let retireDays: Double = 60

    /// 来源硬度：lesson（用户纠正/失败教训）> agent-tool（显式保存）>
    /// 手动（source 空）> 自动提取（source = 会话标题）。
    static func sourceHardness(_ fact: MemoryFact) -> Int {
        switch fact.source {
        case "lesson": return 4
        case "agent-tool": return 3
        case .none: return 2
        case .some(let s): return s.isEmpty ? 2 : 1
        }
    }

    /// 簇代表：来源硬度优先，其次最新。
    static func representative(_ cluster: [MemoryFact]) -> MemoryFact {
        cluster.max { a, b in
            let ha = sourceHardness(a), hb = sourceHardness(b)
            if ha != hb { return ha < hb }
            return a.updatedAt < b.updatedAt
        } ?? cluster[0]
    }

    /// 退役判定：>60 天未用、usageCount=0、非 pinned。
    static func isRetirable(_ fact: MemoryFact, now: Date,
                            retireDays: Double = retireDays) -> Bool {
        guard !fact.pinned else { return false }
        guard (fact.usageCount ?? 0) == 0 else { return false }
        let anchor = fact.lastUsedAt ?? fact.updatedAt
        return now.timeIntervalSince(anchor) > retireDays * 86_400
    }

    /// 严格阈值聚簇：贪心单遍——每条与**已有簇代表**比（O(n·k)，200 条上限
    /// 下足够）。只返回 ≥2 条的簇（单例直接进 kept）。
    static func clusters(_ facts: [MemoryFact],
                         threshold: Double = mergeThreshold) -> [[MemoryFact]] {
        var out: [[MemoryFact]] = []
        outer: for fact in facts {
            let norm = MemoryModels.normalizeFact(fact.content)
            for (i, cluster) in out.enumerated() {
                let rep = representative(cluster)
                if MemoryModels.bigramSimilarity(
                    MemoryModels.normalizeFact(rep.content), norm) >= threshold {
                    out[i].append(fact)
                    continue outer
                }
            }
            out.append([fact])
        }
        return out.filter { $0.count > 1 }
    }

    /// 整卷执行：合并 → 退役。pinned 全程不动。返回 kept（落盘新数组）、
    /// removed（调用方导出归档 + 记墓碑）与报告。
    static func run(_ facts: [MemoryFact], now: Date,
                    pendingConflicts: Int) -> (kept: [MemoryFact], removed: [MemoryFact], report: Report) {
        let totalBefore = facts.count
        let pinnedFacts = facts.filter { $0.pinned }
        let pool = facts.filter { !$0.pinned }

        var removed: [MemoryFact] = []
        var mergedClusters = 0
        var mergedRemovedCount = 0
        for cluster in clusters(pool) {
            let rep = representative(cluster)
            removed.append(contentsOf: cluster.filter { $0.id != rep.id })
            mergedClusters += 1
        }
        mergedRemovedCount = removed.count
        let removedIDs = Set(removed.map(\.id))

        var retiredFacts: [MemoryFact] = []
        let kept = pool
            .filter { !removedIDs.contains($0.id) }
            .filter { fact in
                if isRetirable(fact, now: now) { retiredFacts.append(fact); return false }
                return true
            }
        removed.append(contentsOf: retiredFacts)

        let report = Report(totalBefore: totalBefore,
                            mergedClusters: mergedClusters,
                            mergedRemoved: mergedRemovedCount,
                            retired: retiredFacts.count,
                            pendingConflicts: pendingConflicts)
        return (pinnedFacts + kept, removed, report)
    }
}
