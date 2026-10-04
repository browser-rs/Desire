import Foundation

/// 一个模型的 token 单价：**美元 / 每百万 token**（与各家报价单同一口径）。
///
/// 价格**由用户填**，不内置价格表：服务商改价是常事，内置一份只会很快变成
/// 错的信息，而"错的成本"比"没有成本"更糟。两个字段都是 0 表示未知/免费 →
/// 不显示成本（显示 $0.0000 会让人以为这个服务不花钱）。
struct ModelPrice: Codable, Equatable {
    var inputPerMTok: Double = 0
    var outputPerMTok: Double = 0

    var isKnown: Bool { inputPerMTok > 0 || outputPerMTok > 0 }

    /// 一次调用的成本。单价未知时返回 nil（调用方据此决定"不显示"而不是"显示 0"）。
    func cost(promptTokens: Int, completionTokens: Int) -> Double? {
        guard isKnown else { return nil }
        return Double(promptTokens) / 1_000_000 * inputPerMTok
             + Double(completionTokens) / 1_000_000 * outputPerMTok
    }
}
