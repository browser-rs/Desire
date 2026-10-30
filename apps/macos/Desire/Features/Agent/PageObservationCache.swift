import Foundation
import WebKit

/// 观测缓存（v0.8.25 observe-once-act-many）：同一 webview + 同读取参数 +
/// 短窗口内复用上一份 `__desireSnapshot` 结果，省一次页内序列化与往返。
/// 副作用工具执行后、或发生导航时整体失效（URL 变化由复用校验兜底）。
///
/// 缓存只存"已经产出过的字符串"——不改变任何工具语义；过期/参数不同
/// 就照旧去读页面。
@MainActor
final class PageObservationCache {
    static let shared = PageObservationCache()

    private struct Key: Hashable {
        let maxChars: Int
        let maxElements: Int
        let ignoreSels: String
    }

    /// 每个 webview 最多留 4 组参数（getPageSnapshot / readTab / DPP 变体）。
    private static let perTabLimit = 4
    private var entries: [ObjectIdentifier: [Key: PageObservation]] = [:]

    private init() {}

    /// 命中：返回文本与年龄（年龄用于给模型的复用提示）。
    func reusable(webView: WKWebView, maxChars: Int, maxElements: Int,
                  ignoreSels: String, now: Date = Date()) -> (text: String, age: TimeInterval)? {
        let id = ObjectIdentifier(webView)
        let key = Key(maxChars: maxChars, maxElements: maxElements, ignoreSels: ignoreSels)
        guard let entry = entries[id]?[key] else { return nil }
        guard let text = PageObservationCore.reusable(
            entry, url: webView.url?.absoluteString ?? "",
            maxChars: maxChars, maxElements: maxElements, ignoreSels: ignoreSels,
            now: now) else {
            // 过期/失效的条目顺手清掉，避免长期占内存。
            entries[id]?[key] = nil
            if entries[id]?.isEmpty == true { entries[id] = nil }
            return nil
        }
        return (text, now.timeIntervalSince(entry.storedAt))
    }

    func store(webView: WKWebView, maxChars: Int, maxElements: Int,
               ignoreSels: String, text: String, now: Date = Date()) {
        // 只缓存结构化快照（错误/空结果不缓存，下一次要重试）。
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return }
        let id = ObjectIdentifier(webView)
        let key = Key(maxChars: maxChars, maxElements: maxElements, ignoreSels: ignoreSels)
        var bucket = entries[id] ?? [:]
        if bucket.count >= Self.perTabLimit, bucket[key] == nil {
            // 简单淘汰：丢掉最早写入的一组。
            if let oldest = bucket.min(by: { $0.value.storedAt < $1.value.storedAt }) {
                bucket[oldest.key] = nil
            }
        }
        bucket[key] = PageObservationCore.makeEntry(
            url: webView.url?.absoluteString ?? "", maxChars: maxChars,
            maxElements: maxElements, ignoreSels: ignoreSels, text: text, now: now)
        entries[id] = bucket
    }

    /// 副作用动作后失效（点击/输入/导航都可能重排 DOM）。
    func invalidate(webView: WKWebView) {
        entries[ObjectIdentifier(webView)] = nil
    }

    func invalidateAll() {
        entries.removeAll()
    }

    /// 诊断用：当前缓存条目数（桥/日志）。
    var count: Int { entries.values.reduce(0) { $0 + $1.count } }
}
