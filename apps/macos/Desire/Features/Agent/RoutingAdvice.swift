import Foundation

/// 成本 / 延迟感知的**建议式**路由（v0.8.80 批 3）：只给建议与理由，
/// 绝不偷偷换模型——与"方式决定权"同一原则，用户/智能体采纳后才切。
///
/// 纯逻辑（Foundation-only），排序与阈值都在这里，供 harness 单测与桥/面板共用。
nonisolated struct RoutingAdviceCandidate: Equatable {
    var model: String
    var profileID: String?
    var price: ModelPrice?
    /// 观测到的 TTFT / 总时长 p50（毫秒；样本 <3 时调用方应传 nil）。
    var ttftP50: Double?
    var latencyP50: Double?
    var samples: Int = 0
}

nonisolated struct RoutingAdvice: Equatable {
    enum Kind: String {
        /// 更便宜（价格明确更低）。
        case cheaper
        /// 更快（TTFT 明确更低）。
        case faster
        /// 又便宜又快。
        case cheaperAndFaster
    }

    var model: String
    var profileID: String?
    var kind: Kind
    var estimatedCost: Double?
    var currentEstimatedCost: Double?
    /// 相对当前模型省下的比例（0…1）；价格未知时为 nil。
    var savingFraction: Double?
    var ttftP50: Double?
    var latencyP50: Double?
    var samples: Int
}

nonisolated enum RoutingAdviceEngine {
    /// 便宜 10% 以上才建议（波动与四舍五入不该触发换模型的提示）。
    static let priceImprovementThreshold = 0.10
    /// TTFT 快 20% 以上才建议（同样的理由：观测噪声）。
    static let latencyImprovementThreshold = 0.20
    static let maxAdvice = 3

    static func estimateCost(promptTokens: Int, completionTokens: Int, price: ModelPrice?) -> Double? {
        price?.cost(promptTokens: promptTokens, completionTokens: completionTokens)
    }

    /// 返回至多 `maxAdvice` 条建议，按"省得最多 → 最快"排序。
    ///
    /// 诚实性：价格未知的候选**不参与价格比较**；延迟只有样本 ≥3 才参与。
    /// 没有任何可证明的改进时返回空数组（宁可不建议，也不编理由）。
    static func advise(currentModel: String,
                       promptTokens: Int,
                       completionTokens: Int,
                       candidates: [RoutingAdviceCandidate]) -> [RoutingAdvice] {
        let unique = deduplicated(candidates)
        let current = unique.first { $0.model == currentModel }
        let currentCost = estimateCost(promptTokens: promptTokens,
                                       completionTokens: completionTokens,
                                       price: current?.price)
        let currentTTFT = current.flatMap { $0.samples >= 3 ? $0.ttftP50 : nil }

        var out: [RoutingAdvice] = []
        for candidate in unique where candidate.model != currentModel {
            let cost = estimateCost(promptTokens: promptTokens,
                                    completionTokens: completionTokens,
                                    price: candidate.price)
            let ttft = candidate.samples >= 3 ? candidate.ttftP50 : nil

            var cheaper = false
            var saving: Double?
            if let cost, let currentCost, currentCost > 0, cost < currentCost {
                let fraction = (currentCost - cost) / currentCost
                if fraction >= priceImprovementThreshold {
                    cheaper = true
                    saving = fraction
                }
            }
            var faster = false
            if let ttft, let currentTTFT, currentTTFT > 0,
               ttft < currentTTFT * (1 - latencyImprovementThreshold) {
                faster = true
            }
            guard cheaper || faster else { continue }
            let kind: RoutingAdvice.Kind = cheaper && faster
                ? .cheaperAndFaster : (cheaper ? .cheaper : .faster)
            out.append(RoutingAdvice(
                model: candidate.model,
                profileID: candidate.profileID,
                kind: kind,
                estimatedCost: cost,
                currentEstimatedCost: currentCost,
                savingFraction: saving,
                ttftP50: ttft,
                latencyP50: candidate.samples >= 3 ? candidate.latencyP50 : nil,
                samples: candidate.samples))
        }
        return Array(out.sorted { lhs, rhs in
            let ls = lhs.savingFraction ?? 0
            let rs = rhs.savingFraction ?? 0
            if ls != rs { return ls > rs }
            return (lhs.ttftP50 ?? .greatestFiniteMagnitude) < (rhs.ttftP50 ?? .greatestFiniteMagnitude)
        }.prefix(maxAdvice))
    }

    /// 同一个模型可能出现在多个服务里；保留第一个（调用方按偏好排序传入）。
    private static func deduplicated(_ candidates: [RoutingAdviceCandidate]) -> [RoutingAdviceCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.model).inserted }
    }
}
