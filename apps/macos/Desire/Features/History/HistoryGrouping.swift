import Foundation

/// 历史分组视图的**纯逻辑**（v0.7.21；Foundation-only 进 harness）。
/// 面板与桥 `/history?grouped=1` 共用——聚合口径只有一处。
nonisolated enum HistoryGrouping {

    struct DomainGroup {
        let domain: String
        let entries: [HistoryEntry]
    }

    /// 按域名（host）聚组。**组间按组内最新访问降序**——常用站点浮在前面
    /// （原实现按字母序，站点多时要扫全表找常去站）。组内保持传入顺序
    /// （调用方已是新→旧）。无 host（about:blank 等）由调用方归"其它"。
    static func byDomain(_ entries: [HistoryEntry]) -> [DomainGroup] {
        var groups: [String: [HistoryEntry]] = [:]
        for entry in entries {
            let domain = domain(from: entry.url)
            groups[domain, default: []].append(entry)
        }
        return groups
            .map { DomainGroup(domain: $0.key, entries: $0.value) }
            .sorted { a, b in
                let aLatest = a.entries.first?.timestamp ?? .distantPast
                let bLatest = b.entries.first?.timestamp ?? .distantPast
                if aLatest != bLatest { return aLatest > bLatest }
                return a.domain < b.domain
            }
    }

    /// host 提取（URL 解析失败返回空串——调用方决定本地化文案）。
    static func domain(from urlString: String) -> String {
        URL(string: urlString)?.host ?? ""
    }
}
