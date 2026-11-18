import CryptoKit
import Foundation

/// **翻译缓存**（v0.8.62 批 2，Foundation-only 进 tests/run.sh）：
/// 双语对照翻译的块级缓存——同 URL 重开/导航后命中即插，零模型调用。
///
/// 键设计：`urlKey`（scheme+host+path，去 query/fragment——动态参数不参与）
/// + DOM 块序号（data-desire-bi，同页面结构稳定）+ **原文稳定指纹**
/// （SHA256 前 16 hex——`String.hashValue` 每进程随机，绝不可用于跨会话
/// 匹配）。**块粒度**而非整页：单块 hash 天然抗页面级动态噪音（时间戳/
/// 随机数只影响所在块，其余块照常命中）。
///
/// 存储：`DiskStore` key `translation-cache`（防抖异步写，同 DiskStore 语义）；
/// LRU 按"页面最后使用"淘汰，总字符预算 `maxTotalChars`（~20M 字符 ≈
/// 50MB UTF-8，判定纯逻辑 `evictionTargets` 进 harness）。
nonisolated enum TranslationCache {

    static let storeKey = "translation-cache"
    /// 缓存总字符预算（译文与原文指纹之外的正文部分）。
    static let maxTotalChars = 20_000_000

    struct CachedBlock: Codable, Equatable {
        var index: Int
        var hash: String
        var translation: String
    }

    struct CachedPage: Codable, Equatable {
        var urlKey: String
        var lastUsed: Date
        var blocks: [CachedBlock]
    }

    typealias CacheModel = [String: CachedPage]   // key = urlKey

    /// URL → 缓存键：scheme+host+path（query/fragment 不参与），host 小写。
    static func urlKey(for url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil
        comps?.fragment = nil
        if let host = comps?.host?.lowercased() { comps?.host = host }
        return comps?.string ?? url.absoluteString
    }

    /// 原文稳定指纹（SHA256 前 16 hex）。
    static func blockHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 在缓存页里按 (序号, hash) 双匹配取译文——原文变了（hash 不符）不返回。
    static func matches(_ block: CachedBlock, index: Int, text: String) -> Bool {
        block.index == index && block.hash == blockHash(text)
    }

    /// 命中提取：对收集到的 (序号, 原文) 列表返回 {序号: 译文}。
    static func hits(page: CachedPage?, pairs: [(index: Int, text: String)]) -> [Int: String] {
        guard let page else { return [:] }
        var byKey: [Int: String] = [:]
        for block in page.blocks {
            byKey[block.index] = block.translation
        }
        var hits: [Int: String] = [:]
        for (index, text) in pairs {
            if let translation = byKey[index],
               let block = page.blocks.first(where: { $0.index == index }),
               matches(block, index: index, text: text) {
                hits[index] = translation
            }
        }
        return hits
    }

    /// 把本轮翻译结果并进缓存模型（存在页面则更新块/时间，不存在新建）。
    static func merged(model: CacheModel, urlKey: String,
                       results: [(index: Int, text: String, translation: String)],
                       now: Date = Date()) -> CacheModel {
        var model = model
        var page = model[urlKey] ?? CachedPage(urlKey: urlKey, lastUsed: now, blocks: [])
        page.lastUsed = now
        for r in results {
            let block = CachedBlock(index: r.index, hash: blockHash(r.text),
                                    translation: r.translation)
            if let idx = page.blocks.firstIndex(where: { $0.index == r.index }) {
                page.blocks[idx] = block
            } else {
                page.blocks.append(block)
            }
        }
        page.blocks.sort { $0.index < $1.index }
        model[urlKey] = page
        return model
    }

    /// LRU 淘汰目标：按 lastUsed 从旧到新删页面，直到总字符数（译文长度
    /// 之和）回到预算内。返回待删 urlKey 列表（判定纯逻辑，IO 由调用方做）。
    static func evictionTargets(_ pages: [CachedPage],
                                maxTotalChars: Int = maxTotalChars) -> [String] {
        let total = pages.reduce(0) { $0 + $1.blocks.reduce(0) { $0 + $1.translation.count } }
        guard total > maxTotalChars else { return [] }
        var remaining = total
        var targets: [String] = []
        for page in pages.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            targets.append(page.urlKey)
            remaining -= page.blocks.reduce(0) { $0 + $1.translation.count }
            if remaining <= maxTotalChars { break }
        }
        return targets
    }
}
