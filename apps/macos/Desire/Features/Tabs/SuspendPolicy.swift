import Foundation

/// 内存管家（v0.8.84 批 3 第 14 件，纯逻辑进 harness）：既有挂起策略是
/// 均一时间阈值（30 分钟）+ 单标签超重（>25k 节点）——多个中等页面加
/// 起来再重也不会提前挂起。这里补**总量预算**维度：后台标签 DOM 总量
/// 超过预算时按"重量 × 最久未看"逐个挂起最重的，直到回到预算内。
/// 豁免集（选中/分屏/固定/播放/Agent 租约…）由调用方过滤，这里只做
/// 纯决策。
nonisolated enum SuspendPolicy {

    /// 预算判定：0 = 关闭管家（永远不因总量挂起）。
    static func shouldSuspend(totalNodes: Int, budget: Int) -> Bool {
        guard budget > 0 else { return false }
        return totalNodes > budget
    }

    /// 挂起顺序：重者优先；同重最久未看优先。`nodes <= 0` 视为 1（未知
    /// 重量的标签不第一个被挑，也不被跳过）。
    static func evictionOrder(_ tabs: [(id: UUID, nodes: Int, lastAccessed: Date)]) -> [UUID] {
        tabs.sorted { a, b in
            let wa = Double(max(1, a.nodes))
            let wb = Double(max(1, b.nodes))
            if wa != wb { return wa > wb }
            return a.lastAccessed < b.lastAccessed
        }.map(\.id)
    }
}
