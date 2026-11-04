import CryptoKit
import Foundation

/// 整页翻译缓存（v0.8.43）：按页存 `reader.translations.<url 摘要>`。
/// key 用 SHA-256 十六进制摘要——URL 里有路径分隔符与保留字符，不适合直接当
/// UserDefaults 键。
nonisolated enum ReaderTranslationStore {

    static func key(for pageURL: String) -> String {
        let digest = SHA256.hash(data: Data(pageURL.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "reader.translations.\(hex)"
    }

    static func load(_ pageURL: String) -> ReaderTranslationCache {
        DiskStore.load(ReaderTranslationCache.self, key: key(for: pageURL))
            ?? ReaderTranslationCache()
    }

    static func save(_ cache: ReaderTranslationCache, for pageURL: String) {
        DiskStore.save(cache, key: key(for: pageURL))
    }
}
