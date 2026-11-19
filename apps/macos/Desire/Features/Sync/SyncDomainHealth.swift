import Foundation

/// **同步健康派生**（v0.8.65 批 1，Foundation-only 进 tests/run.sh）：
/// 快拨成对重复事故（0.8.64 发版日实测，b10fc03d 修复）的可观测收口——
/// "地址即身份"的平铺 URL 域（快拨/阅读列表/书签叶子）显示同址重复组数，
/// 设置页健康卡与桥 `GET /sync/health` 消费同一份派生。
///
/// 口径约定：归一化 = trim + 小写 + 去尾斜杠（**保留 query**——书签的
/// `?page=2` 是不同收藏）；`extra = 条目数 − 组数`，即"多出来的份数"。
/// 书签域**只显示不去重**（多处收藏是语义）——UI 层标注豁免。
nonisolated enum SyncDomainHealth {

    struct URLDuplicates: Equatable {
        /// 同址分组数（1 = 无重复）。
        var groups: Int
        /// 多出来的份数（条目数 − 组数）。
        var extra: Int
        var total: Int

        static let clean = URLDuplicates(groups: 0, extra: 0, total: 0)
    }

    /// URL 列表的同址重复统计；空 URL 跳过（不算重复也不计入总数）。
    static func urlDuplicates(_ urls: [String]) -> URLDuplicates {
        var buckets: [String: Int] = [:]
        var total = 0
        for raw in urls {
            let key = normalizeURL(raw)
            guard !key.isEmpty else { continue }
            buckets[key, default: 0] += 1
            total += 1
        }
        let groups = buckets.count
        let extra = total - groups
        if total == 0 { return .clean }
        return URLDuplicates(groups: groups, extra: max(0, extra), total: total)
    }

    /// URL 归一化：trim + 小写 + 去尾斜杠（保留 query/fragment）。
    static func normalizeURL(_ url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// 单域健康行（桥/卡共用结构）。
    struct Row {
        var domain: String
        var localCount: Int?
        /// 本地墓碑数（nil = 该域无显式删除语义）。
        var tombstoneCount: Int?
        /// 游标是否已有值（false = 从未增量拉取过）。
        var hasCursor: Bool
    }
}
