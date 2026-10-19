import Foundation

/// 归档历史检索（v0.7.25）：**服务端存的是密文**（端到端加密）——服务端无法做
/// 全文检索；正解是客户端按需全量拉取 → 本地解密 → 过滤。本文件是纯过滤逻辑
///（Foundation-only，进 harness）；拉取/解密在 SyncStore。
nonisolated enum HistoryArchiveSearch {
    struct Hit: Equatable {
        var title: String
        var url: String
        var timestamp: Date
        var visitCount: Int
    }

    /// query 空 = 全部（按时间倒序）；大小写不敏感子串匹配 title/url；
    /// 同 URL 去重（保留最新一条）；limit 封顶（≥1）。
    static func match(_ payloads: [HistorySyncPayload], query: String,
                      limit: Int = 50) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hits: [Hit] = []
        for payload in payloads {
            if !needle.isEmpty {
                let haystack = (payload.title + "\n" + payload.url).lowercased()
                guard haystack.contains(needle) else { continue }
            }
            hits.append(Hit(title: payload.title, url: payload.url,
                            timestamp: payload.timestamp,
                            visitCount: max(1, payload.visitCount)))
        }
        hits.sort { $0.timestamp > $1.timestamp }
        var seen = Set<String>()
        var out: [Hit] = []
        let cap = max(1, limit)
        for hit in hits where !seen.contains(hit.url) {
            seen.insert(hit.url)
            out.append(hit)
            if out.count == cap { break }
        }
        return out
    }
}
