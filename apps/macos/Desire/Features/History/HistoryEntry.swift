import Foundation

struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    var url: String
    var title: String
    var timestamp: Date
    /// 本地最后修改时间（云同步 LWW 盖戳；标题校正等编辑会推进）。
    /// 旧本地文件缺键 → nil，加载时以 timestamp 兜底归一（不清数据）。
    var updatedAt: Date? = nil
    /// 访问次数（地址栏建议的频率加权；重复访问就地累计并提到最前——
    /// 同 URL 不再每访一条）。旧本地文件缺键 → 1（兼容解码）。
    var visitCount: Int = 1

    /// 建议排序评分：**新近度 × 频率**（Chrome 式"最常且最近"）。
    /// 频率 = sqrt(visitCount)（10 次只值 3 倍——防单一站点霸榜）；
    /// 新近度 = 距上次访问的**小时数**衰减（24h 内 1.0，越旧越低，7 天 0.25）。
    /// 纯函数——tests/run.sh 覆盖排序矩阵。
    func suggestionScore(now: Date = Date()) -> Double {
        let hours = max(0, now.timeIntervalSince(timestamp) / 3600)
        let recency = 1.0 / (1.0 + hours / 24.0)
        return recency * sqrt(Double(max(1, visitCount)))
    }
}
