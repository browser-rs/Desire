import Foundation

/// 观测缓存（v0.8.25 observe-once-act-many）的纯逻辑：一次读取的结果在
/// 同一页、同参数、短窗口内可复用；URL 变化、参数变化或过期即失效。
nonisolated struct PageObservation: Equatable, Sendable {
    var url: String
    var maxChars: Int
    var maxElements: Int
    var ignoreSels: String
    var text: String
    var storedAt: Date
}

nonisolated enum PageObservationCore {
    /// 复用窗口（秒）：足够覆盖同一轮的连续读取，又短到能容忍页面自更新。
    static let ttl: TimeInterval = 8

    /// 命中则返回可复用的快照文本，否则 nil（调用方去真的读页面）。
    static func reusable(_ entry: PageObservation?, url: String,
                         maxChars: Int, maxElements: Int, ignoreSels: String,
                         now: Date, ttl: TimeInterval = PageObservationCore.ttl) -> String? {
        guard let entry else { return nil }
        guard entry.url == url else { return nil }
        guard entry.maxChars == maxChars, entry.maxElements == maxElements,
              entry.ignoreSels == ignoreSels else { return nil }
        let age = now.timeIntervalSince(entry.storedAt)
        guard age >= 0, age <= ttl else { return nil }
        return entry.text
    }

    static func makeEntry(url: String, maxChars: Int, maxElements: Int,
                          ignoreSels: String, text: String, now: Date) -> PageObservation {
        PageObservation(url: url, maxChars: maxChars, maxElements: maxElements,
                        ignoreSels: ignoreSels, text: text, storedAt: now)
    }

    /// 复用提示（附在快照末尾，模型据此知道可加 refresh:true 强制重读）。
    static func note(age: TimeInterval) -> String {
        let seconds = max(1, Int(age.rounded()))
        return "\n[observation reused: page unchanged for \(seconds)s since the previous snapshot — pass refresh:true to force a fresh read]"
    }
}
