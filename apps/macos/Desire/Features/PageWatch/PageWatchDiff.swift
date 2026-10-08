import Foundation

/// 页面监视的变化区域提取（v0.7.5 智能监视）：剥掉公共前缀/后缀，
/// 取变化核心并保留上下文。纯 Foundation（tests/run.sh 覆盖）。
enum PageWatchDiff {
    static func extractChangedRegion(old: String, new: String, context: Int) -> String {
        let o = Array(old), n = Array(new)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, suffix < n.count - prefix,
              o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        if prefix >= n.count - suffix { return old }
        let ctxStart = max(0, prefix - context)
        let ctxEnd = min(n.count, n.count - suffix + context)
        var region = String(n[ctxStart..<ctxEnd])
        if ctxStart > 0 { region = "…" + region }
        if ctxEnd < n.count { region += "…" }
        return region
    }
}
