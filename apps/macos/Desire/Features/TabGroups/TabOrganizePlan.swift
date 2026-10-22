import Foundation

/// 标签整理的分组计划（纯逻辑，进 harness）。
///
/// 规则：按站点 host（去 `www.`）聚合**尚未分组**的普通标签；同一站点达到
/// 阈值（默认 3）才成组，避免把两三个不同站点硬塞成组。已存在的分组不动。
nonisolated enum TabOrganizePlan {
    struct Group: Equatable {
        let host: String
        let tabIDs: [UUID]
    }

    static func groups(for tabs: [(id: UUID, host: String)],
                       threshold: Int = 3) -> [Group] {
        var byHost: [String: [UUID]] = [:]
        var order: [String] = []
        for tab in tabs {
            let host = normalize(tab.host)
            guard !host.isEmpty else { continue }
            if byHost[host] == nil { order.append(host) }
            byHost[host, default: []].append(tab.id)
        }
        return order.compactMap { host in
            guard let ids = byHost[host], ids.count >= max(2, threshold) else { return nil }
            return Group(host: host, tabIDs: ids)
        }
    }

    static func normalize(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// 稳定的颜色下标（同一站点每次整理颜色一致）。
    static func colorIndex(for host: String) -> Int {
        var hash = 5381
        for byte in host.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash) % 8
    }
}
