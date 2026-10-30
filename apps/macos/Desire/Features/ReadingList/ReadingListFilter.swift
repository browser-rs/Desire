import Foundation

/// 阅读列表的搜索与筛选（v0.7.28）：纯逻辑，面板与潜在桥共用。
nonisolated enum ReadingListFilter: String, CaseIterable {
    case all
    case unread
    case offline

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .unread: return String(localized: "Unread")
        case .offline: return String(localized: "Offline")
        }
    }

    /// query 匹配 title/url/summary（大小写不敏感）；filter 按状态过滤；
    /// `tag` 非 nil 时再按标签过滤（v0.8.25，大小写不敏感）。
    /// `cachedIDs` 由调用方从 Store 的离线缓存状态派生（模型里的 cachedFile 可能
    /// 指向已被清掉/换机的文件，不能单独作为"已缓存"判据）。
    static func apply(_ items: [ReadingListItem], query: String,
                      filter: ReadingListFilter, cachedIDs: Set<UUID>,
                      tag: String? = nil) -> [ReadingListItem] {
        var result = items
        switch filter {
        case .all:
            break
        case .unread:
            result = result.filter { !$0.isRead }
        case .offline:
            result = result.filter { cachedIDs.contains($0.id) }
        }
        if let tag, !tag.isEmpty {
            result = result.filter { ReadingListTags.matches(tags: $0.tagList, filter: tag) }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return result }
        return result.filter { item in
            item.title.lowercased().contains(needle)
                || item.url.lowercased().contains(needle)
                || (item.summary ?? "").lowercased().contains(needle)
                || item.tagList.contains { $0.lowercased().contains(needle) }
        }
    }
}
