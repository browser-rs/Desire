import Foundation

/// 整章翻译的块模型与按书缓存（v0.8.36）。Foundation-only，进 harness。
nonisolated struct EbookTranslationBlock: Codable, Equatable, Sendable {
    var id: Int
    var text: String
}

nonisolated struct EbookChapterTranslation: Codable, Equatable, Sendable {
    var language: String
    /// block id（字符串）→ 译文
    var blocks: [String: String]
    var updatedAt: Date
}

nonisolated struct EbookTranslationCache: Codable, Equatable, Sendable {
    /// chapterIndex（字符串）→ 该章最近一次翻译
    var chapters: [String: EbookChapterTranslation] = [:]

    static let maxChapters = 60

    mutating func save(chapter: Int, language: String, translations: [Int: String]) {
        let blocks = Dictionary(uniqueKeysWithValues: translations.map {
            (String($0.key), $0.value)
        })
        chapters[String(chapter)] = EbookChapterTranslation(
            language: language, blocks: blocks, updatedAt: Date())
        trim()
    }

    func translations(chapter: Int, language: String) -> [Int: String]? {
        guard let entry = chapters[String(chapter)], entry.language == language else {
            return nil
        }
        var result: [Int: String] = [:]
        for (key, value) in entry.blocks {
            if let id = Int(key) { result[id] = value }
        }
        return result.isEmpty ? nil : result
    }

    mutating func remove(chapter: Int) {
        chapters.removeValue(forKey: String(chapter))
    }

    mutating func trim() {
        guard chapters.count > Self.maxChapters else { return }
        let keep = chapters.sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(Self.maxChapters)
        chapters = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
