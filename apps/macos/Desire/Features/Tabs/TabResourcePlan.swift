import Foundation

/// 标签资源中心的数据快照（v0.8.1）：纯值，便于排序/去重与单测。
nonisolated struct TabResourceItem: Equatable {
    let id: UUID
    let url: String
    let title: String
    let host: String
    let isSuspended: Bool
    let isPinned: Bool
    let isIncognito: Bool
    let isPlayingAudio: Bool
    let groupName: String?
}

/// 标签资源中心的聚合逻辑（纯逻辑，进 harness）：按站点汇总、识别重复
/// 页面、计算可挂起的后台标签。WebKit 不公开每标签内存，所以这里做的是
/// **可行动的资源视图**（挂起/去重/按站关闭），不假装有精确内存数字。
nonisolated enum TabResourcePlan {
    struct HostRow: Equatable {
        let host: String
        let count: Int
        let suspended: Int
        let playingAudio: Int
        let tabIDs: [UUID]
    }

    struct DuplicateGroup: Equatable {
        /// 归一化后的 URL（展示用原文取首条）。
        let keyURL: String
        let displayURL: String
        let tabIDs: [UUID]
    }

    static func hostRows(_ items: [TabResourceItem]) -> [HostRow] {
        var byHost: [String: [TabResourceItem]] = [:]
        var order: [String] = []
        for item in items {
            guard !item.host.isEmpty else { continue }
            if byHost[item.host] == nil { order.append(item.host) }
            byHost[item.host, default: []].append(item)
        }
        return order.map { host in
            let group = byHost[host] ?? []
            return HostRow(host: host,
                           count: group.count,
                           suspended: group.filter(\.isSuspended).count,
                           playingAudio: group.filter(\.isPlayingAudio).count,
                           tabIDs: group.map(\.id))
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
        }
    }

    /// 重复页面：同一归一化 URL 出现 ≥2 次（跳过新标签页、非 http(s)、
    /// **固定标签**与跨无痕/普通模式的组合——固定是有意保留，私密页不应被
    /// 普通页的去重动作波及）。
    static func duplicates(_ items: [TabResourceItem]) -> [DuplicateGroup] {
        var byKey: [String: [TabResourceItem]] = [:]
        var order: [String] = []
        for item in items {
            guard !item.isPinned else { continue }
            let normalized = normalizeURL(item.url)
            guard !normalized.isEmpty else { continue }
            let key = normalized + (item.isIncognito ? "|private" : "")
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let group = byKey[key], group.count >= 2 else { return nil }
            return DuplicateGroup(keyURL: normalizeURL(group[0].url),
                                  displayURL: group[0].url,
                                  tabIDs: group.map(\.id))
        }
    }

    /// 可安全挂起的后台标签：非当前/分屏/固定/无痕、未挂起，且**没在放声音**
    ///（挂起正在播放的标签会把音乐/视频掐掉）。
    static func suspendable(_ items: [TabResourceItem],
                            selectedID: UUID?,
                            splitID: UUID?) -> [UUID] {
        items.filter {
            !$0.isSuspended && !$0.isPinned && !$0.isIncognito && !$0.isPlayingAudio
                && $0.id != selectedID && $0.id != splitID
        }.map(\.id)
    }

    /// URL 归一：http(s) only；scheme/host 小写、去 fragment 与尾部斜杠，
    /// query 保留（不同查询通常是不同页面）。
    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return "" }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string ?? trimmed
    }
}
