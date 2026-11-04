import Foundation

/// 阅读模式整页翻译的块模型与按页缓存（v0.8.43）。Foundation-only，进 harness。
/// 语义与电子书的 `EbookTranslationCache` 一致：block id（段落标记序号）→ 译文，
/// 换语言覆盖旧译文，页数超上限按最近使用淘汰。
nonisolated struct ReaderTranslationBlock: Codable, Equatable, Sendable {
    var id: Int
    var text: String
}

nonisolated struct ReaderTranslationCache: Codable, Equatable, Sendable {
    /// 页面 URL → 该页最近一次翻译
    var pages: [String: PageTranslation] = [:]

    nonisolated struct PageTranslation: Codable, Equatable, Sendable {
        var language: String
        /// 段落 id（字符串）→ 译文
        var blocks: [String: String]
        var updatedAt: Date
    }

    static let maxPages = 40

    mutating func save(pageURL: String, language: String, translations: [Int: String]) {
        let blocks = Dictionary(uniqueKeysWithValues: translations.map {
            (String($0.key), $0.value)
        })
        pages[pageURL] = PageTranslation(
            language: language, blocks: blocks, updatedAt: Date())
        trim()
    }

    func translations(pageURL: String, language: String) -> [Int: String]? {
        guard let entry = pages[pageURL], entry.language == language else { return nil }
        var result: [Int: String] = [:]
        for (key, value) in entry.blocks {
            if let id = Int(key) { result[id] = value }
        }
        return result.isEmpty ? nil : result
    }

    mutating func remove(pageURL: String) {
        pages.removeValue(forKey: pageURL)
    }

    mutating func trim() {
        guard pages.count > Self.maxPages else { return }
        let keep = pages.sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(Self.maxPages)
        pages = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
