import Foundation

/// 历史去重与清理向导（v0.8.10）纯逻辑：找出"语义重复"的历史行——
/// 同一规范 URL 因 scheme/trailing-slash/utm 等差异分裂的多条——并给出
/// 合并计划（保留最新、次数相加、标题取最长的非空值）。Foundation-only。
nonisolated enum HistoryDedupePlan {

    struct DuplicateGroup: Equatable {
        /// 规范键（canonical URL）。
        let key: String
        /// 组内行（新→旧）。
        let entryIDs: [UUID]
        var count: Int { entryIDs.count }
    }

    struct MergePlan: Equatable {
        /// 保留的行（每组最新的一条）。
        let keepID: UUID
        /// 被吸收的行 id（删除）。
        let dropIDs: [UUID]
        /// 合并后的访问次数。
        let mergedVisitCount: Int
        /// 合并后的标题（最长非空）。
        let mergedTitle: String
        /// 合并后的时间戳（组内最新）。
        let mergedTimestamp: Date
    }

    /// 规范化 URL：scheme 统一 https、去尾斜杠、剥 utm_*/fbclid 参数、
    /// 去 www.（fragment 直接丢）。
    static func canonicalURL(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw) else { return raw }
        comps.scheme = "https"
        comps.fragment = nil
        if let host = comps.host?.lowercased() {
            comps.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if var items = comps.queryItems, !items.isEmpty {
            let tracked = ["utm_source", "utm_medium", "utm_campaign", "utm_term",
                           "utm_content", "fbclid", "gclid", "spm", "share_token"]
            items.removeAll { tracked.contains(($0.name ?? "").lowercased()) }
            if items.isEmpty { comps.query = nil } else { comps.queryItems = items }
        }
        // 路径仅剩 "/" 时视为根（尾斜杠差异归一）
        // 尾斜杠差异归一：路径以 "/" 结尾时剥掉（根路径除外——已在下一行归一）。
        if comps.path.count > 1, comps.path.hasSuffix("/") { comps.path = String(comps.path.dropLast()) }
        if comps.path == "/" { comps.path = "" }
        return comps.string!
    }

    /// 行 → 规范键分组（输入任意序；组内按时间新→旧）。
    static func duplicateGroups(_ entries: [HistoryEntry]) -> [DuplicateGroup] {
        var byKey: [String: [HistoryEntry]] = [:]
        for e in entries {
            byKey[canonicalURL(e.url), default: []].append(e)
        }
        return byKey.compactMap { key, group -> DuplicateGroup? in
            guard group.count >= 2 else { return nil }
            let ids = group.sorted { $0.timestamp > $1.timestamp }.map(\.id)
            return DuplicateGroup(key: key, entryIDs: ids)
        }
        .sorted { $0.count > $1.count }
    }

    /// 合并计划（每组）：保留最新行、visitCount 相加、标题取最长非空。
    static func mergePlan(for group: DuplicateGroup,
                          entries: [HistoryEntry]) -> MergePlan? {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let members = group.entryIDs.compactMap { byID[$0] }
        guard let keep = members.first else { return nil }
        let totalVisits = members.reduce(0) { $0 + $1.visitCount }
        let bestTitle = members
            .map(\.title)
            .max { $0.count < $1.count } ?? keep.title
        return MergePlan(
            keepID: keep.id,
            dropIDs: Array(members.dropFirst().map(\.id)),
            mergedVisitCount: totalVisits,
            mergedTitle: bestTitle,
            mergedTimestamp: keep.timestamp)
    }
}
