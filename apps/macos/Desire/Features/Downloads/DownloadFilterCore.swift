import Foundation

/// 下载面板的过滤与搜索规则（v0.8.25）——纯逻辑（进 harness）。
///
/// 状态过滤刻意不用 `DownloadItem.State`：暂停是"进行中 + isPaused"的组合
/// （见 DownloadItem），面板要的是用户语义上的四态。
nonisolated enum DownloadStatusFilter: String, CaseIterable, Sendable {
    case all, active, paused, completed, failed
}

nonisolated enum DownloadFilterCore {
    /// 状态过滤。`state` 取 `DownloadItem.State.rawValue`；暂停行也算 paused
    /// （不论底层 state 是 .paused 还是 .inProgress）。
    static func matchesStatus(_ filter: DownloadStatusFilter, state: String, isPaused: Bool) -> Bool {
        switch filter {
        case .all:
            return true
        case .active:
            return state == "inProgress" && !isPaused
        case .paused:
            return isPaused || state == "paused"
        case .completed:
            return state == "completed"
        case .failed:
            return state == "failed"
        }
    }

    /// 搜索：文件名、来源完整 URL、来源 host 任意命中即可；空查询恒真。
    static func matchesQuery(filename: String, sourceURL: String?, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if filename.localizedCaseInsensitiveContains(trimmed) { return true }
        guard let sourceURL, !sourceURL.isEmpty else { return false }
        return sourceURL.localizedCaseInsensitiveContains(trimmed)
    }

    /// URL 的 host（去掉 `www.`，小写）——"按站点搜索"的展示口径。
    static func host(of urlString: String?) -> String? {
        guard let urlString,
              let host = URL(string: urlString)?.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
